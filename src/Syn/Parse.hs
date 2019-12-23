module Syn.Parse where

import           Data.List                      ( groupBy )
import           Data.Maybe                     ( isJust
                                                , fromMaybe
                                                )
import           Data.Void                      ( Void )
import           Data.Functor                   ( void )
import           Control.Monad                  ( guard )

import           Text.Megaparsec
import           Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer    as L

import           Syntax

type Parser = Parsec Void String

-- TODO: markdown in comments & doctests
-- TODO: escape quote chars in string literals
-- TOOD: heredocs
-- TODO: do notation
-- TODO: where clause
-- TODO: records
-- TODO: record field syntax
-- TODO: typeclass constraints
-- TODO: infix constructors (like List ::)
-- TODO: empty data types (e.g. Void)

parseLamFile :: String -> Either String (Module Syn)
parseLamFile input = case parse (pModule <* eof) "" input of
  Left  e -> Left (errorBundlePretty e)
  Right e -> Right e

pModule :: Parser (Module Syn)
pModule = do
  metadata <- optional pMetadata
  void $ symbol "module"
  name    <- lexemeN pModuleName
  exports <- optional . lexemeN . parens $ pName `sepBy` comma
  imports <- many (lexemeN pImport)
  decls   <- many (lexemeN pDecl)
  pure $ Module { moduleName     = name
                , moduleImports  = imports
                , moduleExports  = fromMaybe [] exports
                , moduleDecls    = decls
                , moduleMetadata = fromMaybe [] metadata
                }

-- ---
-- key1: val1
-- key2: 2
-- ---
pMetadata :: Parser [(String, String)]
pMetadata = do
  void $ string "---" >> newline
  items <- many pMetaItem
  void $ string "---" >> newline
  pure items
 where
  pMetaItem :: Parser (String, String)
  pMetaItem = do
    key <- lowercaseString
    void (symbol ":")
    val <- many alphaNumChar
    void newline
    pure (key, val)

-- import Bar
-- import qualified Baz as Boo (fun1, fun2)
pImport :: Parser Import
pImport = do
  void $ symbol "import"
  qualified <- isJust <$> optional (symbol "qualified")
  name      <- pModuleName
  alias     <- optional (symbol "as" >> uppercaseName)
  items     <- optional $ parens (pName `sepBy` comma)
  pure Import { importQualified = qualified
              , importName      = name
              , importAlias     = alias
              , importItems     = fromMaybe [] items
              }

-- We ensure that comments are parsed last so that they get attached to a
-- function if directly above one.
pDecl :: Parser (Decl Syn)
pDecl =
  TypeclassDecl
    <$> pTypeclass
    <|> TypeclassInst
    <$> pInstance
    <|> DataDecl
    <$> pData
    <|> try (FunDecl <$> pFun)
    <|> Comment
    <$> pComment

pData :: Parser Data
pData = do
  void (symbol "data")
  name   <- uppercaseName
  tyvars <- many lowercaseName
  void (symbolN "=")
  constructors <- lexemeN pCon `sepBy` symbolN "|"
  pure Data { dataName = name, dataTyVars = tyvars, dataCons = constructors }
 where
  pCon :: Parser DataCon
  pCon = DataCon <$> uppercaseName <*> many pConType

-- TODO: we can make this more flexible by allowing annotations separate from
-- definitions
pFun :: Parser (Fun Syn)
pFun = do
  comments         <- many pComment
  name             <- lowercaseName <?> "declaration type name"
  (constraint, ty) <- symbol ":" >> lexemeN pFunSig
  defs             <- many (lexemeN (pDef name))
  pure Fun { funComments   = comments
           , funName       = name
           , funType       = ty
           , funConstraint = constraint
           , funDefs       = defs
           }

-- Monoid a => [a] -> a
pFunSig :: Parser (Maybe Constraint, Ty)
pFunSig = do
  constraint <- optional (try (pConstraint <* lexeme "=>"))
  ty         <- pType
  pure (constraint, ty)

pConstraint :: Parser Constraint
pConstraint =
  let one   = CInst <$> uppercaseName <*> (map TyVar <$> some lowercaseName)
      multi = do
        cs <- parens (pConstraint `sepBy2` comma)
        pure (foldl1 CTuple cs)
  in  one <|> multi

-- TODO: currently we require at least one typeclass method
-- and no newlines between the class line and the first method
pTypeclass :: Parser Typeclass
pTypeclass = do
  void (symbol "class")
  name   <- uppercaseName
  tyvars <- some lowercaseName
  void (symbol "where" >> some newline)
  indentation <- some (char ' ')
  first       <- pTypeclassDef
  rest        <- many (string indentation >> pTypeclassDef)
  pure Typeclass { typeclassName   = name
                 , typeclassTyVars = tyvars
                 , typeclassDefs   = first : rest
                 }
 where
  pTypeclassDef :: Parser (Name, Ty)
  pTypeclassDef = do
    name       <- lowercaseName
    annotation <- symbol ":" >> lexeme pType
    void (optional newline)
    pure (name, annotation)

pInstance :: Parser (Instance Syn)
pInstance = do
  void (symbol "instance")
  name  <- uppercaseName
  types <- many pType
  void (symbol "where" >> some newline)
  indentation <- some (char ' ')
  first       <- pDef'
  rest        <- many (try (newline >> string indentation) >> pDef')
  -- Convert [(Name, Def)] into [(Name, [Def])] (grouped by name)
  let defs = map (\ds -> (fst (head ds), map snd ds))
        $ groupBy (\x y -> fst x == fst y) (first : rest)
  pure Instance { instanceName  = name
                , instanceTypes = types
                , instanceDefs  = defs
                }

pDef :: Name -> Parser (Def Syn)
pDef (Name name) = do
  void (symbol name)
  bindings <- many pPattern <?> "pattern"
  void (symbolN "=")
  expr <- pExpr
  pure Def { defArgs = bindings, defExpr = expr }

-- Like pDef but will parse a definition with any name
pDef' :: Parser (Name, Def Syn)
pDef' = do
  name     <- lexeme lowercaseName
  bindings <- many pPattern <?> "pattern"
  void (symbolN "=")
  expr <- pExpr
  pure (name, Def { defArgs = bindings, defExpr = expr })

-- Int
-- Maybe Int
-- a
-- a -> b
pType :: Parser Ty
pType = try arr <|> try app <|> pType'
 where
  arr = do
    left <- lexemeN (try app <|> pType')
    void $ symbolN "->"
    right <- lexeme pType
    pure $ left `fn` right
  app = do
    first <- lexeme pType'
    rest  <- some (lexeme pType')
    pure $ foldl1 (:@:) (first : rest)
  pType' = hole <|> try tuple <|> parens pType <|> var <|> con <|> list
  con    = TyCon <$> uppercaseName
  var    = TyVar <$> lowercaseName
  hole   = TyHole <$> (string "?" >> pHoleName)
  list   = TyList <$> brackets pType
  tuple  = TyTuple <$> parens (lexemeN pType `sepBy2` comma)

-- Parses the type args to a constructor
-- The rules are slightly different from types in annotations, because type
-- application must be inside parentheses
-- i.e. MyCon f a   -> name = MyCon, args = [f, a]
-- vs.  func : f a  -> name = func, type = f :@: a
pConType :: Parser Ty
pConType = ty
 where
  ty    = var <|> con <|> list <|> parens (try arr <|> try tuple <|> app)
  app   = (:@:) <$> ty <*> ty
  arr   = TyArr <$ symbol "->"
  con   = TyCon <$> uppercaseName
  var   = TyVar <$> lowercaseName
  list  = TyList <$> brackets ty
  tuple = TyTuple <$> ty `sepBy2` comma

pPattern :: Parser Pattern
pPattern = pPattern' <|> cons
 where
  tyCon          = uppercaseName
  cons           = try nullaryCon <|> try infixBinaryCon <|> con
  nullaryCon     = ConsPat <$> tyCon <*> pure []
  infixBinaryCon = parens $ do
    left  <- pPattern
    tycon <- binTyCon
    right <- pPattern
    pure $ ConsPat tycon [left, right]
  -- For now, the only infix constructor is (::)
  binTyCon = Name <$> symbol "::"
  con      = parens $ do
    c    <- tyCon
    args <- many pPattern
    pure $ ConsPat c args

pPattern' :: Parser Pattern
pPattern' = try int <|> wild <|> list <|> try tuple <|> var
 where
  int   = IntPat <$> pInt
  wild  = symbol "_" >> pure WildPat
  list  = ListPat <$> brackets (pPattern `sepBy` comma)
  tuple = TuplePat <$> parens (pPattern `sepBy` comma)
  var   = VarPat <$> lowercaseName

-- Case patterns differ from function patterns in that a constructor pattern
-- doesn't have to be in parentheses (because we are only scrutinising a single
-- expression).
-- e.g. case foo of
--        Just x -> ...
-- is valid whereas
-- foo Just x = ...
-- is not the same as
-- foo (Just x) = ...
pCasePattern :: Parser Pattern
pCasePattern = pPattern' <|> con
  where con = ConsPat <$> uppercaseName <*> many pPattern

pInt :: Parser Int
pInt = do
  sign   <- optional (string "-")
  digits <- lexeme (some digitChar)
  pure . read $ fromMaybe "" sign <> digits

pFloat :: Parser Double
pFloat = do
  sign    <- optional (string "-")
  numeral <- many digitChar
  void (string ".")
  decimal <- lexeme (some digitChar)
  pure . read $ fromMaybe "" sign <> numeral <> "." <> decimal

pExpr :: Parser Syn
pExpr = try pBinApp <|> try pApp <|> pExpr'

pExpr' :: Parser Syn
pExpr' =
  try pTuple
    <|> parens pExpr
    <|> pHole
    <|> try pStringLit
    <|> try (FloatLit <$> pFloat)
    <|> try (IntLit <$> pInt)
    <|> pVar
    <|> pAbs
    <|> pLet
    <|> pList
    <|> pCons
    <|> pCase

-- Application of a binary operator
-- e.g. x + y
-- TODO: fixity?
-- Maybe handle this after parsing
pBinApp :: Parser Syn
pBinApp = do
  left <- pExpr'
  op   <- pOp
  void $ some (char ' ')
  right <- pExpr'
  pure $ App (App op left) right
 where
  pOp :: Parser Syn
  pOp =
    (Cons . Name <$> string "::") <|> (Var . Name <$> (twoCharOp <|> oneCharOp))
  twoCharOp =
    string "&&" <|> string "||" <|> string ">=" <|> string "<=" <> string "<>"
  oneCharOp = (: []) <$> oneOf ['+', '-', '*', '/', '>', '<']

pApp :: Parser Syn
pApp = do
  first <- pExpr'
  rest  <- some pExpr'
  pure $ foldl1 App (first : rest)

pHole :: Parser Syn
pHole = do
  void (string "?")
  Hole <$> pHoleName

-- "hello"
-- "hello #{name}"
-- "hello #{name + "!"}"
pStringLit :: Parser Syn
pStringLit = do
  void (string "\"")
  (prefix, interps) <- pInner
  void (symbol "\"")
  pure $ StringLit prefix interps
 where
  pRawString :: Parser String
  pRawString = takeWhileP Nothing (\c -> c /= '"' && c /= '#')
  pInterp :: Parser Syn
  pInterp = do
    void (string "#{")
    e <- pExpr
    void (string "}")
    return e
  pInner :: Parser (String, [(Syn, String)])
  pInner = do
    prefix <- pRawString
    -- after the #, we either have a string interpolation or just more raw string
    next   <- Left <$> pInterp <|> Right <$> pRawString
    case next of
      Left e -> do
        (str, interps) <- pInner
        pure (prefix, (e, str) : interps)
      Right s
        | null s -> pure (prefix, [])
        | otherwise -> do
          (str, interps) <- pInner
          pure (prefix <> s <> str, interps)

pVar :: Parser Syn
pVar = Var <$> lowercaseName

pAbs :: Parser Syn
pAbs = do
  void (string "\\")
  args <- many lowercaseName
  void (symbol "->")
  Abs <$> pure args <*> pExpr

-- let foo = 1
--     bar = 2
--  in x
pLet :: Parser Syn
pLet = do
  void (symbolN "let")
  binds <- many (lexemeN pBind)
  void (symbolN "in")
  Let binds <$> pExpr
 where
  pBind :: Parser (Name, Syn)
  pBind = do
    var <- lowercaseName
    void (symbol "=")
    val <- pExpr
    lexemeN (void newline)
    pure (var, val)

pTuple :: Parser Syn
pTuple = TupleLit <$> parens (pExpr `sepBy2` comma)

pList :: Parser Syn
pList = ListLit
  <$> between (symbolN "[") (symbol "]") (lexemeN pExpr `sepBy` lexemeN comma)

pCons :: Parser Syn
pCons = Cons <$> uppercaseName

pCase :: Parser Syn
pCase = do
  void (symbol "case")
  scrutinee <- pExpr
  void (symbol "of")
  void newline
  indentation <- some (char ' ')
  first       <- pAlt
  rest        <- many $ try (newline >> string indentation >> pAlt)
  pure $ Case scrutinee (first : rest)
 where
  pAlt :: Parser (Pattern, Syn)
  pAlt = do
    pat <- pCasePattern
    void (symbol "->")
    expr <- pExpr
    pure (pat, expr)

pComment :: Parser String
pComment = do
  void (symbol "--")
  s <- takeWhileP (Just "comment") (/= '\n')
  spaceConsumerN
  pure s

pName :: Parser Name
pName = uppercaseName <|> lowercaseName

pModuleName :: Parser ModuleName
pModuleName = ModuleName <$> lexeme (uppercaseString' `sepBy` string ".")
 where
  -- like uppercaseString but doesn't consume trailing space
  uppercaseString' :: Parser String
  uppercaseString' = (:) <$> upperChar <*> many alphaNumChar

pHoleName :: Parser Name
pHoleName = lexeme $ Name <$> do
  s <- some alphaNumChar
  guard (s `notElem` keywords)
  pure s

uppercaseName :: Parser Name
uppercaseName = lexeme $ Name <$> do
  t <- (:) <$> upperChar <*> many alphaNumChar
  guard (t `notElem` keywords)
  pure t

lowercaseName :: Parser Name
lowercaseName = Name <$> lowercaseString

lowercaseString :: Parser String
lowercaseString = lexeme . try $ do
  t <- (:) <$> (lowerChar <|> char '$') <*> many alphaNumChar
  guard (t `notElem` keywords)
  pure t

keywords :: [String]
keywords =
  [ "data"
  , "qualified"
  , "as"
  , "let"
  , "in"
  , "case"
  , "of"
  , "class"
  , "where"
  , "instance"
  , "module"
  , "import"
  ]

-- Consumes spaces and tabs
spaceConsumer :: Parser ()
spaceConsumer = L.space (void $ some (char ' ')) empty empty

-- Consumes spaces, tabs and newlines
spaceConsumerN :: Parser ()
spaceConsumerN = L.space (void (some spaceChar)) empty empty

-- Parses a specific string, skipping trailing spaces and tabs
symbol :: String -> Parser String
symbol = L.symbol spaceConsumer

-- Like symbol but also skips trailing newlines
symbolN :: String -> Parser String
symbolN = L.symbol spaceConsumerN

-- Runs the given parser, skipping trailing spaces and tabs
lexeme :: Parser a -> Parser a
lexeme = L.lexeme spaceConsumer

-- Like lexeme but also skips trailing newlines
lexemeN :: Parser a -> Parser a
lexemeN = L.lexeme spaceConsumerN

parens :: Parser p -> Parser p
parens = between (symbol "(") (symbol ")")

brackets :: Parser p -> Parser p
brackets = between (symbol "[") (symbol "]")

comma :: Parser String
comma = symbol ","

-- Like sepBy1 but parses at least _two_ occurrences of p
-- Useful for when you need to be sure you have a tuple type rather than just a
-- variable in parentheses
sepBy2 :: Parser a -> Parser sep -> Parser [a]
sepBy2 p sep = do
  first <- p
  void sep
  rest <- p `sepBy1` sep
  pure (first : rest)
{-# INLINE sepBy2 #-}