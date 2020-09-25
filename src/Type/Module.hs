module Type.Module where

-- Typecheck a Lam module
-- Currently we just return unit (and an updated type env) if the module
-- typechecked. In future we will need to return a copy of the module with full
-- type annotations.

import qualified Data.Set                      as Set
import           Util

import qualified Syn                           as S
import           Syn                            ( Decl_(..)
                                                , Data_(..)
                                                , Module_(..)
                                                , DataCon_(..)
                                                , Fun_(..)
                                                )
import           Data.Name
import qualified Canonical                     as Can
import           Type                           ( TypeM
                                                , Type(..)
                                                , Ctx
                                                , CtxElem(Var)
                                                , V(..)
                                                , Exp
                                                , check
                                                , infer
                                                , wellFormedType
                                                , LocatedError(..)
                                                , newU
                                                )
import           Type.FromSyn                   ( fromSyn
                                                , convertType
                                                )
import           Control.Monad                  ( void )
import qualified Control.Monad.Except          as Except
                                                ( throwError
                                                , catchError
                                                )
import qualified Syn.Typed                     as T
import qualified Type.ToTyped                   ( convertModule )

-- Translate a module into typechecking structures, and return them
-- Used for debugging
translateModule :: Can.Module -> TypeM (Ctx, [(Name, Maybe Type, Exp)])
translateModule modul = do
  dataTypeCtx <- mconcat
    <$> mapM translateData (getDataDecls (moduleDecls modul))
  funs <- mapM funToBind $ getFunDecls (moduleDecls modul)
  pure (dataTypeCtx, funs)

-- TODO: return a type-annotated module
-- TODO: check that data type definitions are well-formed
checkModule :: Ctx -> Can.Module -> TypeM (Ctx, T.Module)
checkModule ctx modul = do
  -- Extract type signatures from all datatype definitions in the module
  dataTypeCtx <- mconcat
    <$> mapM translateData (getDataDecls (moduleDecls modul))

  -- Get all the functions defined in the module
  funs <- mapM funToBind $ getFunDecls (moduleDecls modul)

  -- Split the functions into those with type signatures and those without
  let (funsWithSig, funsWithoutSig) = flip partitionWith funs $ \case
        (name, Just ty, expr) -> Left (name, ty, expr)
        (name, Nothing, expr) -> Right (name, expr)


  -- Extend the context with type signatures for each function
  -- This allows us to typecheck them in any order, and to typecheck any
  -- recursive calls.
  -- If the function has no type signature (should only happen when we're
  -- invoking this function via the REPL), skip it.
  let funTypeCtx = map (\(name, ty, _exp) -> Var (Free name) ty) funsWithSig

  let ctx'       = ctx <> dataTypeCtx <> funTypeCtx

  -- Typecheck each function definition
  -- For functions with type signatures, just check them against their signature
  -- For functions without type signatures, infer their type
  mapM_ (checkFun ctx') funsWithSig
  mapM_ (inferFun ctx') funsWithoutSig

  -- Construct a typed module by converting every data & fun decl into the typed
  -- form, with empty type annotations. In the future this should be done during
  -- typechecking itself.
  let typedModule = Type.ToTyped.convertModule modul

  -- Done
  pure (ctx', typedModule)

checkFun :: Ctx -> (Name, Type, Exp) -> TypeM ()
checkFun ctx (name, ty, body) =
  flip Except.catchError
       (\(LocatedError _ e) -> Except.throwError (LocatedError (Just name) e))
    $ do
  -- check the type is well-formed
        void $ wellFormedType ctx ty
        -- check the body of the function
        void $ check ctx body ty

inferFun :: Ctx -> (Name, Exp) -> TypeM ()
inferFun ctx (name, body) =
  flip Except.catchError
       (\(LocatedError _ e) -> Except.throwError (LocatedError (Just name) e))
    $ do
        -- infer the body of the function
        void $ infer ctx body

funToBind :: Can.Fun Can.Exp -> TypeM (Name, Maybe Type, Exp)
funToBind fun = do
  rhs <- fromSyn (funExpr fun)
  sch <- case funType fun of
    Just t  -> Just <$> quantify (Set.toList (S.ftv t)) t
    Nothing -> pure Nothing
  pure (funName fun, sch, rhs)

-- Explicitly quantify all type variables, then convert the whole thing to a
-- T.Type.
quantify :: [Name] -> Can.Type -> TypeM Type
quantify vars t = do
  uMap <- mapM (\v -> (v, ) <$> newU v) vars
  t'   <- convertType uMap t
  pure $ foldr (Forall . snd) t' uMap

-- Convert data type definitions into a series of <constructor, type> bindings.
--
--   type Maybe a = Just a | Nothing
-- becomes
--   Var (Free "Just") (Forall a. a -> Maybe a)
--   Var (Free "Nothing") (Forall a. Maybe a)
--
--   type Functor f = Functor { map : forall a b. (a -> b) -> f a -> f b }
-- becomes
--   Var (Free "Functor") (Forall f. { map : Forall a b. (a -> b) -> f a -> f b })
--
translateData :: Can.Data -> TypeM Ctx
translateData d =
  let tyvars = map Local (dataTyVars d)
  in  mapM (go (dataName d) tyvars) (dataCons d)
 where
  go :: Name -> [Name] -> Can.DataCon -> TypeM CtxElem
  go dataTypeName tyvars datacon = do
    -- Construct a (Syn) Scheme for this constructor
    let resultType = foldl S.TyApp (S.TyCon dataTypeName) (map S.TyVar tyvars)
    ty <- quantify tyvars $ foldr S.TyFun resultType (conArgs datacon)
    pure $ Var (Free (conName datacon)) ty

getFunDecls :: [Decl_ n e ty] -> [Fun_ n e ty]
getFunDecls = getDeclBy $ \case
  FunDecl f -> Just f
  _         -> Nothing

getDataDecls :: [Decl_ n e ty] -> [Data_ n]
getDataDecls = getDeclBy $ \case
  DataDecl d -> Just d
  _          -> Nothing

getDeclBy :: (Decl_ n e ty -> Maybe a) -> [Decl_ n e ty] -> [a]
getDeclBy _       []         = []
getDeclBy extract (d : rest) = case extract d of
  Just e  -> e : getDeclBy extract rest
  Nothing -> getDeclBy extract rest
