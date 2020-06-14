module LC.Execute where

-- This module takes an LC expression representing an IO action and executes it.
-- Typically this will be the 'main' binding of a program.
-- This differs from LC.Eval in that we will execute any foreign calls in the
-- program. The result of executing an LC expression of type IO a will be an LC
-- expression of type a.

import           Data.Functor                   ( ($>) )

import           ELC                            ( Con(..)
                                                , Constant(..)
                                                )
import           LC
import           LC.Eval                        ( eval )
import           ELC.Primitive                  ( listNil
                                                , listCons
                                                )
import           Data.Name

executeMain :: ModuleName -> Env -> IO Exp
executeMain mn = executeVar (TopLevel mn "main")

executeVar :: Name -> Env -> IO Exp
executeVar n env = execute env (Var n)

execute :: Env -> Exp -> IO Exp
execute env expr = case expr of
  FCall proc args -> do
    result <- executeFCall env proc args
    execute env result
  e ->
    let reduced = eval env e
    in  if reduced /= e then execute env reduced else pure e

executeFCall :: Env -> String -> [Exp] -> IO Exp
executeFCall env name args = case (name, args) of
  ("putStrLn", [Const (String s) _]) -> putStrLn s $> unit
  ("putStr"  , [Const (String s) _]) -> putStr s $> unit
  ("getLine" , []                  ) -> do
    str <- getLine
    pure $ Const (String str) []
  ("bindIO", [mx, f]) -> do
    x <- execute env mx
    execute env (App f x)
  ("pureIO", [x]                 ) -> pure x
  ("chars" , [Const (String s) _]) -> pure $ foldl
    (\cs c -> Cons listCons [Const (Char c) [], cs])
    (Cons listNil [])
    s
  ("showChar", [Const (Char c) _]) -> pure $ Const (String [c]) []
  _ ->
    error
      $  "Cannot execute foreign call '"
      <> name
      <> "' with args "
      <> show args

unit :: Exp
unit = Cons Prod { conName = "Unit", conArity = 0 } []
