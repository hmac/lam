module Test.Syn.Parse
  ( test
  )
where

import           Test.Hspec
import           Test.Hspec.Megaparsec
import           Text.Megaparsec                ( parse )
import           Syn.Parse                      ( pModule
                                                , pDecl
                                                , pExpr
                                                , pType
                                                )

import           Syn


test :: Spec
test = parallel $ do
  describe "parsing declarations" $ do
    it "parses a basic function definition" $ do
      parse pDecl "" "id : a -> a\nid x = x" `shouldParse` FunDecl Fun
        { funComments   = []
        , funName       = "id"
        , funType       = Just (TyVar "a" `fn` TyVar "a")
        , funDefs       = [Def { defArgs = [VarPat "x"], defExpr = Var "x" }]
        }

    it "parses a definition with multiple type arrows" $ do
      parse pDecl "" "const : a -> b -> a\nconst x y = x" `shouldParse` FunDecl
        Fun
          { funComments   = []
          , funName       = "const"
          , funType       = Just $ TyVar "a" `fn` TyVar "b" `fn` TyVar "a"
          , funDefs       = [ Def { defArgs = [VarPat "x", VarPat "y"]
                                  , defExpr = Var "x"
                                  }
                            ]
          }
    it "parses a higher kinded type definition" $ do
      parse pDecl "" "map : (a -> b) -> f a -> f b\nmap f m = undefined"
        `shouldParse` FunDecl Fun
                        { funComments   = []
                        , funName       = "map"
                        , funType       = Just
                                          $    (TyVar "a" `fn` TyVar "b")
                                          `fn` (TyCon "f" [TyVar "a"])
                                          `fn` (TyCon "f" [TyVar "b"])
                        , funDefs = [ Def { defArgs = [VarPat "f", VarPat "m"]
                                          , defExpr = Var "undefined"
                                          }
                                    ]
                        }
    it "parses a multiline function definition" $ do
      parse
          pDecl
          ""
          "head : [a] -> a\nhead [] = error \"head: empty list\"\nhead (Cons x xs) = x"
        `shouldParse` FunDecl Fun
                        { funComments   = []
                        , funName       = "head"
                        , funType = Just $ TyList (TyVar "a") `fn` TyVar "a"
                        , funDefs       =
                          [ Def
                            { defArgs = [ListPat []]
                            , defExpr = App (Var "error")
                                            (StringLit "head: empty list" [])
                            }
                          , Def
                            { defArgs = [ ConsPat "Cons"
                                                  [VarPat "x", VarPat "xs"]
                                        ]
                            , defExpr = Var "x"
                            }
                          ]
                        }
    it "parses a function with a multi param argument type" $ do
      parse
          pDecl
          ""
          "fromLeft : Either a b -> Maybe a\nfromLeft (Left x) = Just x\nfromLeft (Right _) = Nothing"
        `shouldParse` FunDecl Fun
                        { funComments   = []
                        , funName       = "fromLeft"
                        , funType       = Just
                                          $ (TyCon "Either" [TyVar "a", TyVar "b"])
                                          `fn` (TyCon "Maybe" [TyVar "a"])
                        , funDefs       =
                          [ Def { defArgs = [ConsPat "Left" [VarPat "x"]]
                                , defExpr = App (Con "Just") (Var "x")
                                }
                          , Def { defArgs = [ConsPat "Right" [WildPat]]
                                , defExpr = Con "Nothing"
                                }
                          ]
                        }

    it "parses a simple type definition" $ do
      parse pDecl "" "type Unit = Unit" `shouldParse` DataDecl Data
        { dataName   = "Unit"
        , dataTyVars = []
        , dataCons   = [DataCon { conName = "Unit", conArgs = [] }]
        }
    it "parses a record definition" $ do
      parse pDecl "" "type Foo a = Foo { unFoo : a, label : ?b, c : A A }"
        `shouldParse` DataDecl Data
                        { dataName   = "Foo"
                        , dataTyVars = ["a"]
                        , dataCons   =
                          [ RecordCon
                              { conName   = "Foo"
                              , conFields = [ ("unFoo", TyVar "a")
                                            , ("label", TyHole "b")
                                            , ("c", TyCon "A" [TyCon "A" []])
                                            ]
                              }
                          ]
                        }
    it "parses the definition of List" $ do
      parse pDecl "" "type List a = Nil | Cons a (List a)"
        `shouldParse` DataDecl Data
                        { dataName   = "List"
                        , dataTyVars = ["a"]
                        , dataCons   =
                          [ DataCon { conName = "Nil", conArgs = [] }
                          , DataCon
                            { conName = "Cons"
                            , conArgs = [TyVar "a", TyCon "List" [TyVar "a"]]
                            }
                          ]
                        }
  describe "parsing modules" $ do
    it "parses a basic module with metadata" $ do
      parse pModule "" "---\nkey: val\n---\nmodule Foo\none : Int\none = 1"
        `shouldParse` Module
                        { moduleName     = "Foo"
                        , moduleImports  = []
                        , moduleExports  = []
                        , moduleDecls    =
                          [ FunDecl Fun
                              { funName       = "one"
                              , funComments   = []
                              , funType       = Just (TyCon "Int" [])
                              , funDefs       = [ Def { defArgs = []
                                                      , defExpr = IntLit 1
                                                      }
                                                ]
                              }
                          ]
                        , moduleMetadata = [("key", "val")]
                        }
    it "parses a module with imports and exports" $ do
      parse
          pModule
          ""
          "module Foo (fun1, fun2)\nimport Bar\nimport qualified Bar.Baz as B (fun3, fun4, Foo(..), Bar(BarA, BarB))"
        `shouldParse` Module
                        { moduleName     = "Foo"
                        , moduleImports  =
                          [ Import { importQualified = False
                                   , importName      = ModuleName ["Bar"]
                                   , importAlias     = Nothing
                                   , importItems     = []
                                   }
                          , Import
                            { importQualified = True
                            , importName      = ModuleName ["Bar", "Baz"]
                            , importAlias     = Just "B"
                            , importItems = [ ImportSingle "fun3"
                                            , ImportSingle "fun4"
                                            , ImportAll "Foo"
                                            , ImportSome "Bar" ["BarA", "BarB"]
                                            ]
                            }
                          ]
                        , moduleExports  = [("fun1", []), ("fun2", [])]
                        , moduleDecls    = []
                        , moduleMetadata = []
                        }
  describe "parsing expressions" $ do
    it "parses an application" $ do
      parse pExpr "" "foo x y z"
        `shouldParse` App (App (App (Var "foo") (Var "x")) (Var "y")) (Var "z")
    it "parses an infix application" $ do
      parse pExpr "" "(a <= a)"
        `shouldParse` App (App (Var "<=") (Var "a")) (Var "a")
    it "parses a case expression" $ do
      parse pExpr "" "case x of\n  Just y -> y\n  Nothing -> z"
        `shouldParse` Case
                        (Var "x")
                        [ (ConsPat "Just" [VarPat "y"], Var "y")
                        , (ConsPat "Nothing" []       , Var "z")
                        ]
    it "parses a case with variable patterns" $ do
      parse pExpr "" "case x of\n  y -> y"
        `shouldParse` Case (Var "x") [(VarPat "y", Var "y")]
    it "parses a let expression" $ do
      parse pExpr "" "let x = 1\n    y = 2\n in add x y" `shouldParse` Let
        [("x", IntLit 1), ("y", IntLit 2)]
        (App (App (Var "add") (Var "x")) (Var "y"))
    it "parses a binary operator" $ do
      parse pExpr "" "1 + 1"
        `shouldParse` App (App (Var "+") (IntLit 1)) (IntLit 1)
    it "parses a tuple" $ do
      parse pExpr "" "(\"\", 0)"
        `shouldParse` TupleLit [StringLit "" [], IntLit 0]
    it "parses a string literal" $ do
      parse pExpr "" "\"hello \\\"friend\\\"\""
        `shouldParse` StringLit "hello \"friend\"" []
      parse pExpr "" "\"this is a backslash: \\\\ (#{0})\""
        `shouldParse` StringLit "this is a backslash: \\ (" [(IntLit 0, ")")]
  describe "parsing types" $ do
    it "parses basic function types" $ do
      parse pType "" "a -> b" `shouldParse` (TyVar "a" `fn` TyVar "b")
    it "parses multi arg function types" $ do
      parse pType "" "a -> b -> c"
        `shouldParse` (TyVar "a" `fn` TyVar "b" `fn` TyVar "c")
    it "parses higher order function types" $ do
      parse pType "" "(a -> b) -> a -> b"
        `shouldParse` ((TyVar "a" `fn` TyVar "b") `fn` TyVar "a" `fn` TyVar "b")
    it "parses multi parameter type constructors" $ do
      parse pType "" "Either a b -> Maybe a"
        `shouldParse` (    (TyCon "Either" [TyVar "a", TyVar "b"])
                      `fn` (TyCon "Maybe" [TyVar "a"])
                      )
    it "parses parameterised constructors inside lists" $ do
      parse pType "" "[Maybe a]"
        `shouldParse` TyList (TyCon "Maybe" [TyVar "a"])
    it "parses nested type constructors" $ do
      parse pType "" "A B" `shouldParse` TyCon "A" [TyCon "B" []]
