module Constraint.Generate.Module where

-- Generate constraints for a whole Lam module
-- This basically involves generating constraints for each bind, accumulating an
-- environment as we go.

-- We will need an initial environment containing (possibly unknown) types for
-- any imported items.

import qualified Data.Map.Strict               as Map

import           Constraint.Generate.M
import           Syntax                  hiding ( Name
                                                , fn
                                                )
import           Canonical                      ( Name(..) )
import           Constraint
import           Constraint.Expr                ( Exp
                                                , Scheme(..)
                                                )
import           Constraint.FromSyn             ( fromSyn
                                                , tyToScheme
                                                , tyToType
                                                )
import           Constraint.Generate.Bind
import           Util

generateModule :: Env -> Module_ Name (Syn_ Name) -> GenerateM [BindT]
generateModule env modul = do
  -- Extract data declarations
  let datas = getDataDecls (moduleDecls modul)
  let env'  = foldl generateDataDecl env datas

  --       typeclass declarations
  --       instance declarations

  -- Extract function declarations
  let funs  = getFunDecls (moduleDecls modul)
  let binds = map funToBind funs

  -- Generate uvars for each bind upfront so they can be typechecked in any order
  bindEnv <- mapM (\(Bind n _ _) -> (n, ) . Forall [] mempty . TVar <$> fresh)
                  binds
  let env'' = Map.fromList bindEnv <> env'

  res <- forM binds $ \bind -> do
    (_env, b) <- generateBind env'' bind
    pure (Right b)
  case lefts res of
    []        -> pure (rights res)
    (err : _) -> throwError err

getFunDecls :: [Decl_ n e] -> [Fun_ n e]
getFunDecls (FunDecl f : rest) = f : getFunDecls rest
getFunDecls (_         : rest) = getFunDecls rest
getFunDecls []                 = []

getDataDecls :: [Decl_ n e] -> [Data_ n]
getDataDecls (DataDecl d : rest) = d : getDataDecls rest
getDataDecls (_          : rest) = getDataDecls rest
getDataDecls []                  = []

-- TODO: typeclass constraints
funToBind :: Fun_ Name (Syn_ Name) -> Bind
funToBind fun = Bind (funName fun) (Just scheme) equations
 where
  scheme    = tyToScheme (funType fun)
  equations = map defToEquation (funDefs fun)

defToEquation :: Def_ Name (Syn_ Name) -> ([Pattern_ Name], Exp)
defToEquation Def { defArgs = pats, defExpr = e } = (pats, fromSyn e)

-- Generate new bindings for data declarations.
--
--           data Maybe a = Just a | Nothing
-- generates
--           Just : Forall a. a -> Maybe a
--           Nothing : Forall a.
--
--           data User = User { name : String, age : Int }
-- generates
--           User : String -> Int -> User
--           name : User -> String
--           age  : User -> Int
--
-- TODO: generate record field selectors
generateDataDecl :: Env -> Data_ Name -> Env
generateDataDecl env d =
  let tyvars = map (R . Local) (dataTyVars d)
      tycon  = TCon (dataName d) (map TVar tyvars)
      mkType args = Forall tyvars mempty (foldr (fn . tyToType) tycon args)
      mkCon (DataCon   name args  ) = (name, mkType args)
      mkCon (RecordCon name fields) = (name, mkType (map snd fields))
  in  env <> Map.fromList (map mkCon (dataCons d))
