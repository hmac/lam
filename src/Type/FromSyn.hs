module Type.FromSyn where

-- Convert Syn to Type.Exp, ready for typechecking

import           Util

import           Data.Name                      ( Name
                                                , prim
                                                , toString
                                                )
import qualified Data.Set                      as Set
import           Data.String                    ( fromString )
import           Data.Traversable               ( for )
import           Type                           ( Exp )
import qualified Type                          as T

import           AST
import qualified Canonical                     as Can
import qualified Syn                           as S

fromSyn :: Can.Exp -> T.TypeM Exp
fromSyn = \case
  Var n   -> pure $ Var (T.Free n)
  Con n   -> pure $ Con (T.Free n)
  Ann e t -> Ann <$> fromSyn e <*> convertType mempty t
  Hole n  -> pure $ Hole (T.Free n)
  App a b -> App <$> fromSyn a <*> fromSyn b
  Case scrut alts ->
    Case
      <$> fromSyn scrut
      <*> mapM (bimapM (pure . convertPattern) fromSyn) alts
  MCase alts ->
    MCase <$> mapM (bimapM (pure . map convertPattern) fromSyn) alts
  Abs xs a -> do
    a' <- fromSyn a
    pure $ Abs (map T.Free xs) a'
  Let binds body -> do
    body'  <- fromSyn body
    binds' <- mapM
      (\(n, e, maybeType) -> do
        let t' = for maybeType $ \t -> quantify (Set.toList (S.ftv t)) t
        (T.Free n, , ) <$> fromSyn e <*> t'
      )
      binds

    pure $ Let binds' body'
  UnitLit      -> pure UnitLit
  TupleLit  es -> TupleLit <$> mapM fromSyn es
  ListLit   es -> ListLit <$> mapM fromSyn es
  StringLit s  -> pure $ StringLit s
  StringInterp prefix comps ->
    StringInterp prefix <$> mapM (firstM fromSyn) comps
  CharLit c      -> pure $ CharLit c
  IntLit  i      -> pure $ IntLit i
  BoolLit b      -> pure $ BoolLit b
  Record  r      -> Record <$> mapM (secondM fromSyn) r
  Project r f    -> Project <$> fromSyn r <*> pure f
  FCall   n args -> FCall n <$> mapM fromSyn args

convertPattern :: Can.Pattern -> T.Pattern
convertPattern = \case
  VarPat v -> VarPat (T.Free v)
  ConsPat c _ subpats ->
    ConsPat (T.Free c) Nothing (map convertPattern subpats)
  TuplePat subpats -> TuplePat (map convertPattern subpats)
  ListPat  subpats -> ListPat (map convertPattern subpats)
  WildPat          -> WildPat
  UnitPat          -> UnitPat
  IntPat    i      -> IntPat i
  CharPat   c      -> CharPat c
  BoolPat   b      -> BoolPat b
  StringPat s      -> StringPat s

convertType :: [(Name, T.U)] -> Can.Type -> T.TypeM T.Type
convertType uVarCtx = \case
  S.TyBool   -> pure T.bool
  S.TyInt    -> pure T.int
  S.TyString -> pure T.string
  S.TyChar   -> pure T.char
  S.TyUnit   -> pure T.unit
  S.TyHole _ ->
    T.throwError $ T.TodoError "Type.fromSyn: holes in types not implemented"
  S.TyFun a b -> T.Fn <$> convertType uVarCtx a <*> convertType uVarCtx b
  S.TyTuple as ->
    let name = prim $ fromString $ "Tuple" <> show (length as)
    in  T.TCon name <$> mapM (convertType uVarCtx) as
  S.TyVar v -> case lookup v uVarCtx of
    Just u  -> pure $ T.UType u
    Nothing -> T.throwError $ T.UnknownVariable (T.Free v)
  S.TyCon c   -> pure $ T.TCon c []
  -- Flatten type applications into spine form, so the head of every TApp is
  -- never a TApp. This is an invariant required by the typechecker.
  S.TyApp a b -> do
    b' <- convertType uVarCtx b
    a' <- convertType uVarCtx a
    pure $ case a' of
      T.TCon c args -> T.TCon c $ args ++ [b']
      T.TApp f args -> T.TApp f (args <> [b'])
      _             -> T.TApp a' [b']
  S.TyList -> pure $ T.TCon (prim "List") []
  S.TyRecord fields ->
    T.TRecord <$> mapM (secondM (convertType uVarCtx) . first toString) fields
  S.TyAlias _ _ ->
    T.throwError $ T.TodoError "convertType: type aliases not implemented"
  S.TyForall v t -> do
    u  <- T.newU v
    t' <- convertType ((v, u) : uVarCtx) t
    pure $ T.Forall u t'

-- Explicitly quantify all type variables, then convert the whole thing to a
-- T.Type.
quantify :: [Name] -> Can.Type -> T.TypeM T.Type
quantify vars t = do
  uMap <- mapM (\v -> (v, ) <$> T.newU v) vars
  t'   <- convertType uMap t
  pure $ foldr (T.Forall . snd) t' uMap
