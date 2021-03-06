{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ScopedTypeVariables #-}
module LambdaCube.Compiler.Parser
    ( SData(..)
    , NameDB, caseName, pattern MatchName
    , sourceInfo, SI(..), debugSI
    , Module(..), Visibility(..), Binder(..), SExp'(..), Extension(..), Extensions
    , pattern SVar, pattern SType, pattern Wildcard, pattern SAppV, pattern SLamV, pattern SAnn
    , pattern SBuiltin, pattern SPi, pattern Primitive, pattern SLabelEnd, pattern SLam
    , pattern TyType, pattern Wildcard_
    , debug, LI, isPi, varDB, lowerDB, justDB, upDB, cmpDB, MaxDB (..), iterateN, traceD
    , parseLC, runDefParser
    , getParamsS, addParamsS, getApps, apps', downToS, addForalls
    , mkDesugarInfo, joinDesugarInfo
    , Up (..), up1, up
    , Doc, shLam, shApp, shLet, shLet_, shAtom, shAnn, shVar, epar, showDoc, showDoc_, sExpDoc, shCstr
    , mtrace, sortDefs
    , trSExp', usedS, substSG0, substS
    , Stmt (..), Export (..), ImportItems (..)
    ) where

import Data.Monoid
import Data.Maybe
import Data.List
import Data.Char
import Data.String
import qualified Data.Map as Map
import qualified Data.Set as Set

import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.State
import Control.Arrow hiding ((<+>))
import Control.Applicative

import qualified LambdaCube.Compiler.Pretty as P
import LambdaCube.Compiler.Pretty hiding (Doc, braces, parens)
import LambdaCube.Compiler.Lexer

-------------------------------------------------------------------------------- utils

(<&>) = flip (<$>)

dropNth i xs = take i xs ++ drop (i+1) xs
iterateN n f e = iterate f e !! n
mtrace s = trace_ s $ return ()

-- supplementary data: data with no semantic relevance
newtype SData a = SData a
instance Show (SData a) where show _ = "SData"
instance Eq (SData a) where _ == _ = True
instance Ord (SData a) where _ `compare` _ = EQ

traceD x = if debug then trace_ x else id

debug = False--True--tr

try = try_

-------------------------------------------------------------------------------- builtin precedences

data Prec
    = PrecAtom      --  ( _ )  ...
    | PrecAtom'
    | PrecProj      --  _ ._                {left}
    | PrecSwiz      --  _%_                 {left}
    | PrecApp       --  _ _                 {left}
    | PrecOp
    | PrecArr       --  _ -> _              {right}
    | PrecEq        --  _ ~ _
    | PrecAnn       --  _ :: _              {right}
    | PrecLet       --  _ := _
    | PrecLam       --  \ _ -> _            {right} {accum}
    deriving (Eq, Ord)

-------------------------------------------------------------------------------- expression representation

type SExp = SExp' Void

data Void

instance Show Void where show _ = error "show @Void"
instance Eq Void where _ == _ = error "(==) @Void"

data SExp' a
    = SGlobal SIName
    | SBind SI Binder (SData SIName{-parameter's name-}) (SExp' a) (SExp' a)
    | SApp SI Visibility (SExp' a) (SExp' a)
    | SLet LI (SExp' a) (SExp' a)    -- let x = e in f   -->  SLet e f{-x is Var 0-}
    | SVar_ (SData SIName) !Int
    | SLit SI Lit
    | STyped SI a
  deriving (Eq, Show)

-- let info
type LI = (Bool, SIName)

pattern SVar a b = SVar_ (SData a) b

data Binder
    = BPi  Visibility
    | BLam Visibility
    | BMeta      -- a metavariable is like a floating hidden lambda
  deriving (Eq, Show)

data Visibility = Hidden | Visible
  deriving (Eq, Show)

sLit = SLit mempty
pattern SPi  h a b <- SBind _ (BPi  h) _ a b where SPi  h a b = sBind (BPi  h) (SData (debugSI "patternSPi2", "pattern_spi_name")) a b
pattern SLam h a b <- SBind _ (BLam h) _ a b where SLam h a b = sBind (BLam h) (SData (debugSI "patternSLam2", "pattern_slam_name")) a b
pattern Wildcard t <- SBind _ BMeta _ t (SVar _ 0) where Wildcard t = sBind BMeta (SData (debugSI "pattern Wildcard2", "pattern_wildcard_name")) t (SVar (debugSI "pattern Wildcard2", ".wc") 0)
pattern Wildcard_ si t  <- SBind _ BMeta _ t (SVar (si, _) 0)
pattern SLamV a         = SLam Visible (Wildcard SType) a

pattern SApp' h a b <- SApp _ h a b where SApp' h a b = sApp h a b
pattern SAppH a b       = SApp' Hidden a b
pattern SAppV a b       = SApp' Visible a b
pattern SAppV2 f a b    = f `SAppV` a `SAppV` b

pattern SType       = SBuiltin "'Type"
pattern SAnn a t    = SBuiltin "typeAnn" `SAppH` t `SAppV` a
pattern TyType a    = SAnn a SType
pattern SLabelEnd a = SBuiltin "labelend" `SAppV` a

pattern SBuiltin s <- SGlobal (_, s) where SBuiltin s = SGlobal (debugSI $ "builtin " ++ s, s)

pattern Section e = SBuiltin "^section"  `SAppV` e

sApp v a b = SApp (sourceInfo a <> sourceInfo b) v a b
sBind v x a b = SBind (sourceInfo a <> sourceInfo b) v x a b

isPi (BPi _) = True
isPi _ = False

infixl 2 `SAppV`, `SAppH`

addParamsS ps t = foldr (uncurry SPi) t ps

getParamsS (SPi h t x) = first ((h, t):) $ getParamsS x
getParamsS x = ([], x)

apps' = foldl $ \a (v, b) -> sApp v a b

getApps = second reverse . run where
  run (SApp _ h a b) = second ((h, b):) $ run a
  run x = (x, [])

-- todo: remove
downToS err n m = [SVar (debugSI $ err ++ " " ++ show i, ".ds") (n + i) | i <- [m-1, m-2..0]]

instance SourceInfo (SExp' a) where
    sourceInfo = \case
        SGlobal (si, _)        -> si
        SBind si _ _ e1 e2     -> si
        SApp si _ e1 e2        -> si
        SLet _ e1 e2           -> sourceInfo e1 <> sourceInfo e2
        SVar (si, _) _         -> si
        STyped si _            -> si
        SLit si _              -> si

instance SetSourceInfo (SExp' a) where
    setSI si = \case
        SBind _ a b c d -> SBind si a b c d
        SApp _ a b c    -> SApp si a b c
        SLet le a b     -> SLet le a b
        SVar (_, n) i   -> SVar (si, n) i
        STyped _ t      -> STyped si t
        SGlobal (_, n)  -> SGlobal (si, n)
        SLit _ l        -> SLit si l

-------------------------------------------------------------------------------- low-level toolbox

newtype MaxDB = MaxDB {getMaxDB :: Maybe Int}

instance Monoid MaxDB where
    mempty = MaxDB Nothing
    MaxDB a  `mappend` MaxDB a'  = MaxDB $ Just $ max (fromMaybe 0 a) (fromMaybe 0 a')

instance Show MaxDB where show _ = "MaxDB"

varDB i = MaxDB $ Just $ i + 1

lowerDB (MaxDB i) = MaxDB $ (+ (- 1)) <$> i
justDB (MaxDB i) = MaxDB $ Just $ fromMaybe 0 i

-- 0 means that no free variable is used
-- 1 means that only var 0 is used
--cmpDB i e = i >= maxDB e
cmpDB _ (maxDB_ -> MaxDB x) = isNothing x

maxDB = max 0 . fromMaybe 0 . getMaxDB . maxDB_
upDB n (MaxDB i) = MaxDB $ (\x -> if x == 0 then x else x+n) <$> i

class Up a where
    up_ :: Int -> Int -> a -> a
    up_ n i = iterateN n $ up1_ i
    up1_ :: Int -> a -> a
    up1_ = up_ 1

    fold :: Monoid e => (Int -> Int -> e) -> Int -> a -> e

    used :: Int -> a -> Bool
    used = (getAny .) . fold ((Any .) . (==))

    maxDB_ :: a -> MaxDB

    closedExp :: a -> a
    closedExp a = a

instance (Up a, Up b) => Up (a, b) where
    up_ n i (a, b) = (up_ n i a, up_ n i b)
    used i (a, b) = used i a || used i b
    fold f i (a, b) = fold f i a <> fold f i b
    maxDB_ (a, b) = maxDB_ a <> maxDB_ b
    closedExp (a, b) = (closedExp a, closedExp b)

up n = up_ n 0
up1 = up1_ 0

substS j x = mapS' f2 ((+1) *** up 1) (j, x)
  where
    f2 sn i (j, x) = case compare i j of
        GT -> SVar sn $ i - 1
        LT -> SVar sn i
        EQ -> STyped (fst sn) x

foldS h g f = fs
  where
    fs i = \case
        SApp _ _ a b -> fs i a <> fs i b
        SLet _ a b -> fs i a <> fs (i+1) b
        SBind _ _ _ a b -> fs i a <> fs (i+1) b
        STyped si x -> h i si x
        SVar sn j -> f sn j i
        SGlobal sn -> g sn i
        x@SLit{} -> mempty

freeS = nub . foldS (\_ _ _ -> error "freeS") (\sn _ -> [sn]) mempty 0

usedS n = getAny . foldS (\_ _ _ -> error "usedS") (\sn _ -> Any $ n == sn) mempty 0

mapS' = mapS__ (\_ _ _ -> error "mapS'") (const . SGlobal)
mapS__ hh gg f2 h = g where
    g i = \case
        SApp si v a b -> SApp si v (g i a) (g i b)
        SLet x a b -> SLet x (g i a) (g (h i) b)
        SBind si k si' a b -> SBind si k si' (g i a) (g (h i) b)
        SVar sn j -> f2 sn j i
        SGlobal sn -> gg sn i
        STyped si x -> hh i si x
        x@SLit{} -> x

rearrangeS :: (Int -> Int) -> SExp -> SExp
rearrangeS f = mapS' (\sn j i -> SVar sn $ if j < i then j else i + f (j - i)) (+1) 0
{-
substS'' :: Int -> Int -> SExp' a -> SExp' a
substS'' j' x = mapS' f2 (+1) j'
  where
    f2 sn j i
        | j < i = SVar sn j
        | j == i = SVar sn $ x + (j - j')
        | j > i = SVar sn $ j - 1
-}
substSG j = mapS__ (\_ _ _ -> error "substSG") (\sn x -> if sn == j then SVar sn x else SGlobal sn) (\sn j -> const $ SVar sn j) (+1)
substSG0 n = substSG n 0 . up1

instance Up Void where
    up_ n i = error "up_ @Void"
    fold _ = error "fold_ @Void"
    maxDB_ _ = error "maxDB @Void"

instance Up a => Up (SExp' a) where
    up_ n = mapS' (\sn j i -> SVar sn $ if j < i then j else j+n) (+1)
        where
            mapS' = mapS__ (\i si x -> STyped si $ up_ n i x) (const . SGlobal)

    fold f = foldS (\i si x -> fold f i x) mempty $ \sn j i -> f j i
    maxDB_ _ = error "maxDB @SExp"

dbf' = dbf_ 0
dbf_ j xs e = foldl (\e (i, sn) -> substSG sn i e) e $ zip [j..] xs

dbff :: DBNames -> SExp -> SExp
dbff ns e = foldr substSG0 e ns

trSExp' = trSExp elimVoid

elimVoid :: Void -> a
elimVoid _ = error "impossible"

trSExp :: (a -> b) -> SExp' a -> SExp' b
trSExp f = g where
    g = \case
        SApp si v a b -> SApp si v (g a) (g b)
        SLet x a b -> SLet x (g a) (g b)
        SBind si k si' a b -> SBind si k si' (g a) (g b)
        SVar sn j -> SVar sn j
        SGlobal sn -> SGlobal sn
        SLit si l -> SLit si l
        STyped si a -> STyped si $ f a

-------------------------------------------------------------------------------- expression parsing

parseType mb = maybe id option mb (reservedOp "::" *> parseTTerm PrecLam)
typedIds mb = (,) <$> commaSep1 upperLower <*> parseType mb

hiddenTerm p q = (,) Hidden <$ reservedOp "@" <*> p  <|>  (,) Visible <$> q

telescope mb = fmap dbfi $ many $ hiddenTerm
    (typedId <|> maybe empty (tvar . pure) mb)
    (try "::" typedId <|> maybe ((,) <$> pure (mempty, "") <*> parseTTerm PrecAtom) (tvar . pure) mb)
  where
    tvar x = (,) <$> patVar <*> x
    typedId = parens $ tvar $ parseType mb

dbfi = first reverse . unzip . go []
  where
    go _ [] = []
    go vs ((v, (n, e)): ts) = (n, (v, dbf' vs e)): go (n: vs) ts

parseTTerm = typeNS . parseTerm
parseETerm = expNS . parseTerm

indentation p q = p >> q

setSI' p = appRange $ flip setSI <$> p

parseTerm :: Prec -> P SExp
parseTerm prec = setSI' {-TODO: remove, slow-} $ case prec of
    PrecLam ->
         do level PrecAnn $ \t -> mkPi <$> (Visible <$ reservedOp "->" <|> Hidden <$ reservedOp "=>") <*> pure t <*> parseTTerm PrecLam
     <|> mkIf <$ reserved "if" <*> parseTerm PrecLam <* reserved "then" <*> parseTerm PrecLam <* reserved "else" <*> parseTerm PrecLam
     <|> do reserved "forall"
            (fe, ts) <- telescope (Just $ Wildcard SType)
            f <- SPi . const Hidden <$ reservedOp "." <|> SPi . const Visible <$ reservedOp "->"
            t' <- dbf' fe <$> parseTTerm PrecLam
            return $ foldr (uncurry f) t' ts
     <|> do expNS $ do
                (fe, ts) <- reservedOp "\\" *> telescopePat <* reservedOp "->"
                checkPattern fe
                t' <- dbf' fe <$> parseTerm PrecLam
                ge <- dsInfo
                return $ foldr (uncurry (patLam id ge)) t' ts
     <|> compileCase <$ reserved "case" <*> dsInfo <*> parseETerm PrecLam <* reserved "of" <*> do
            indentMS False $ do
                (fe, p) <- longPattern
                (,) p <$> parseRHS (dbf' fe) "->"
--     <|> compileGuardTree id id <$> dsInfo <*> (Alts <$> parseSomeGuards (const True))
    PrecAnn -> level PrecOp $ \t -> SAnn t <$> parseType Nothing
    PrecOp -> (notOp False <|> notExp) >>= \xs -> join $ calculatePrecs <$> dsInfo <*> pure xs where
        notExp = (++) <$> ope <*> notOp True
        notOp x = (++) <$> try "expression" ((++) <$> ex PrecApp <*> option [] ope) <*> notOp True
             <|> if x then option [] (try "lambda" $ ex PrecLam) else mzero
        ope = pure . Left <$> (rhsOperator <|> psn ("'EqCTt" <$ reservedOp "~"))
        ex pr = pure . Right <$> parseTerm pr
    PrecApp ->
        apps' <$> try "record" ((SGlobal <$> upperCase) <* reservedOp "{") <*> commaSep (lowerCase *> reservedOp "=" *> ((,) Visible <$> parseTerm PrecLam)) <* reservedOp "}"
     <|> apps' <$> parseTerm PrecSwiz <*> many (hiddenTerm (parseTTerm PrecSwiz) $ parseTerm PrecSwiz)
    PrecSwiz -> level PrecProj $ \t -> mkSwizzling t <$> lexeme (try "swizzling" $ char '%' *> manyNM 1 4 (satisfy (`elem` ("xyzwrgba" :: String))))
    PrecProj -> level PrecAtom $ \t -> try "projection" $ mkProjection t <$ char '.' <*> sepBy1 (uncurry SLit . second LString <$> lowerCase) (char '.')
    PrecAtom ->
         mkLit <$> try "literal" parseLit
     <|> Wildcard (Wildcard SType) <$ reserved "_"
     <|> char '\'' *> switchNS (parseTerm PrecAtom)
     <|> SGlobal <$> try "identifier" upperLower
     <|> brackets ( (parseTerm PrecLam >>= \e ->
                mkDotDot e <$ reservedOp ".." <*> parseTerm PrecLam
            <|> foldr ($) (SBuiltin "Cons" `SAppV` e `SAppV` SBuiltin "Nil") <$ reservedOp "|" <*> commaSep (generator <|> letdecl <|> boolExpression)
            <|> mkList <$> namespace <*> ((e:) <$> option [] (symbol "," *> commaSep1 (parseTerm PrecLam)))
            ) <|> mkList <$> namespace <*> pure [])
     <|> mkTuple <$> namespace <*> parens (commaSep $ parseTerm PrecLam)
     <|> mkRecord <$> braces (commaSep $ (,) <$> lowerCase <* symbol ":" <*> parseTerm PrecLam)
     <|> mkLets True <$ reserved "let" <*> dsInfo <*> parseDefs xSLabelEnd <* reserved "in" <*> parseTerm PrecLam
  where
    level pr f = parseTerm pr >>= \t -> option t $ f t

    mkSwizzling term = swizzcall
      where
        sc c = SBuiltin ['S',c]
        swizzcall [x] = SBuiltin "swizzscalar" `SAppV` term `SAppV` (sc . synonym) x
        swizzcall xs  = SBuiltin "swizzvector" `SAppV` term `SAppV` swizzparam xs
        swizzparam xs  = foldl SAppV (vec xs) $ map (sc . synonym) xs
        vec xs = SBuiltin $ case length xs of
            0 -> error "impossible: swizzling parsing returned empty pattern"
            1 -> error "impossible: swizzling went to vector for one scalar"
            n -> "V" ++ show n
        synonym 'r' = 'x'
        synonym 'g' = 'y'
        synonym 'b' = 'z'
        synonym 'a' = 'w'
        synonym c   = c

    mkProjection = foldl $ \exp field -> SBuiltin "project" `SAppV` field `SAppV` exp

    -- Creates: RecordCons @[("x", _), ("y", _), ("z", _)] (1.0, (2.0, (3.0, ())))
    mkRecord xs = SBuiltin "RecordCons" `SAppH` names `SAppV` values
      where
        (names, values) = mkNames *** mkValues $ unzip xs

        mkNameTuple (si, v) = SBuiltin "Tuple2" `SAppV` SLit si (LString v) `SAppV` Wildcard SType
        mkNames = foldr (\n ns -> SBuiltin "Cons" `SAppV` mkNameTuple n `SAppV` ns)
                        (SBuiltin "Nil")

        mkValues = foldr (\x xs -> SBuiltin "Tuple2" `SAppV` x `SAppV` xs)
                         (SBuiltin "Tuple0")

    mkTuple _ [Section e] = e
    mkTuple _ [x] = x
    mkTuple (Namespace level _) xs = foldl SAppV (SBuiltin (tuple ++ show (length xs))) xs
      where tuple = case level of
                Just TypeLevel -> "'Tuple"
                Just ExpLevel -> "Tuple"
                _ -> error "mkTuple"

    mkList (Namespace (Just TypeLevel) _) [x] = SBuiltin "'List" `SAppV` x
    mkList (Namespace (Just ExpLevel)  _) xs = foldr (\x l -> SBuiltin "Cons" `SAppV` x `SAppV` l) (SBuiltin "Nil") xs
    mkList _ xs = error "mkList"

    mkLit n@LInt{} = SBuiltin "fromInt" `SAppV` sLit n
    mkLit l = sLit l

    mkIf b t f = SBuiltin "primIfThenElse" `SAppV` b `SAppV` t `SAppV` f

    mkDotDot e f = SBuiltin "fromTo" `SAppV` e `SAppV` f

    calculatePrecs :: DesugarInfo -> [Either SIName SExp] -> P SExp
    calculatePrecs dcls = either fail return . f where
        f []                 = error "impossible"
        f (Right t: xs)      = either (\(op, xs) -> Section $ SLamV $ SGlobal op `SAppV` up1 (calcPrec' t xs) `SAppV` SVar (mempty, ".rs") 0) (calcPrec' t) <$> cont xs
        f xs@(Left op@(_, "-"): _) = f $ Right (mkLit $ LInt 0): xs
        f (Left op: xs)      = g op xs >>= either (const $ Left "TODO: better error message @476")
                                                  (\((op, e): oe) -> return $ Section $ SLamV $ SGlobal op `SAppV` SVar (mempty, ".ls") 0 `SAppV` up1 (calcPrec' e oe))
        g op (Right t: xs)   = (second ((op, t):) +++ ((op, t):)) <$> cont xs
        g op []              = return $ Left (op, [])
        g op _               = Left "two operator is not allowed next to each-other"
        cont (Left op: xs)   = g op xs
        cont []              = return $ Right []
        cont _               = error "impossible"

        calcPrec' = calcPrec (\op x y -> SGlobal op `SAppV` x `SAppV` y) (getFixity dcls . snd)

    generator, letdecl, boolExpression :: P (SExp -> SExp)
    generator = do
        ge <- dsInfo
        (dbs, pat) <- try "generator" $ longPattern <* reservedOp "<-"
        checkPattern dbs
        exp <- parseTerm PrecLam
        return $ \e ->
                 SBuiltin "concatMap"
         `SAppV` SLamV (compileGuardTree id id ge $ Alts
                    [ compilePatts [(pat, 0)] $ Right $ dbff dbs e
                    , GuardLeaf $ SBuiltin "Nil"
                    ])
         `SAppV` exp

    letdecl = mkLets False <$ reserved "let" <*> dsInfo <*> (compileFunAlts' id =<< valueDef)

    boolExpression = (\pred e -> SBuiltin "primIfThenElse" `SAppV` pred `SAppV` e `SAppV` SBuiltin "Nil") <$> parseTerm PrecLam


    mkPi Hidden (getTTuple' -> xs) b = foldr (sNonDepPi Hidden) b xs
    mkPi h a b = sNonDepPi h a b

    sNonDepPi h a b = SPi h a $ up1 b

getTTuple' (getTTuple -> Just (n, xs)) | n == length xs = xs
getTTuple' x = [x]

getTTuple (SAppV (getTTuple -> Just (n, xs)) z) = Just (n, xs ++ [z]{-todo: eff-})
getTTuple (SGlobal (si, s@(splitAt 6 -> ("'Tuple", reads -> [(n, "")])))) = Just (n :: Int, [])
getTTuple _ = Nothing

patLam :: (SExp -> SExp) -> DesugarInfo -> (Visibility, SExp) -> Pat -> SExp -> SExp
patLam f ge (v, t) p e = SLam v t $ compileGuardTree f f ge $ compilePatts [(p, 0)] $ Right e

-------------------------------------------------------------------------------- pattern representation

data Pat
    = PVar SIName -- Int
    | PCon SIName [ParPat]
    | ViewPat SExp ParPat
    | PatType ParPat SExp
  deriving Show

-- parallel patterns like  v@(f -> [])@(Just x)
newtype ParPat = ParPat [Pat]
  deriving Show

mapPP f = \case
    ParPat ps -> ParPat (mapP f <$> ps)

mapP :: (SExp -> SExp) -> Pat -> Pat
mapP f = \case
    PVar n -> PVar n
    PCon n pp -> PCon n (mapPP f <$> pp)
    ViewPat e pp -> ViewPat (f e) (mapPP f pp)
    PatType pp e -> PatType (mapPP f pp) (f e)

--upP i j = mapP (up_ j i)

varPP = length . getPPVars_
varP = length . getPVars_

type DBNames = [SIName]  -- De Bruijn variable names

getPVars :: Pat -> DBNames
getPVars = reverse . getPVars_

getPPVars = reverse . getPPVars_

getPVars_ = \case
    PVar n -> [n]
    PCon _ pp -> foldMap getPPVars_ pp
    ViewPat e pp -> getPPVars_ pp
    PatType pp e -> getPPVars_ pp

getPPVars_ = \case
    ParPat pp -> foldMap getPVars_ pp

instance SourceInfo ParPat where
    sourceInfo (ParPat ps) = sourceInfo ps

instance SourceInfo Pat where
    sourceInfo = \case
        PVar (si,_)     -> si
        PCon (si,_) ps  -> si <> sourceInfo ps
        ViewPat e ps    -> sourceInfo e  <> sourceInfo ps
        PatType ps e    -> sourceInfo ps <> sourceInfo e

-------------------------------------------------------------------------------- pattern parsing

parsePat :: Prec -> P Pat
parsePat = \case
  PrecAnn ->
        patType <$> parsePat PrecOp <*> parseType (Just $ Wildcard SType)
  PrecOp ->
        calculatePatPrecs <$> dsInfo <*> p_
    where
        p_ = (,) <$> parsePat PrecApp <*> option [] (colonSymbols >>= p)
        p op = do (exp, op') <- try "pattern" ((,) <$> parsePat PrecApp <*> colonSymbols)
                  ((op, exp):) <$> p op'
           <|> pure . (,) op <$> parsePat PrecAnn
  PrecApp ->
         PCon <$> upperCase <*> many (ParPat . pure <$> parsePat PrecAtom)
     <|> parsePat PrecAtom
  PrecAtom ->
         mkLit <$> namespace <*> try "literal" parseLit
     <|> flip PCon [] <$> upperCase
     <|> char '\'' *> switchNS (parsePat PrecAtom)
     <|> PVar <$> patVar
     <|> (\ns -> pConSI . mkListPat ns) <$> namespace <*> brackets patlist
     <|> (\ns -> pConSI . mkTupPat ns) <$> namespace <*> parens patlist
 where
    litP = flip ViewPat (ParPat [PCon (mempty, "True") []]) . SAppV (SBuiltin "==")

    mkLit (Namespace (Just TypeLevel) _) (LInt n) = toNatP n        -- todo: elim this alternative
    mkLit _ n@LInt{} = litP (SBuiltin "fromInt" `SAppV` sLit n)
    mkLit _ n = litP (sLit n)

    toNatP = run where
      run 0         = PCon (mempty, "Zero") []
      run n | n > 0 = PCon (mempty, "Succ") [ParPat [run $ n-1]]

    pConSI (PCon (_, n) ps) = PCon (sourceInfo ps, n) ps
    pConSI p = p

    patlist = commaSep $ parsePat PrecAnn

    mkListPat ns [p] | namespaceLevel ns == Just TypeLevel = PCon (debugSI "mkListPat4", "'List") [ParPat [p]]
    mkListPat ns (p: ps) = PCon (debugSI "mkListPat2", "Cons") $ map (ParPat . (:[])) [p, mkListPat ns ps]
    mkListPat _ [] = PCon (debugSI "mkListPat3", "Nil") []

    --mkTupPat :: [Pat] -> Pat
    mkTupPat ns [x] = x
    mkTupPat ns ps = PCon (debugSI "", tick ns $ "Tuple" ++ show (length ps)) (ParPat . (:[]) <$> ps)

    patType p (Wildcard SType) = p
    patType p t = PatType (ParPat [p]) t

    calculatePatPrecs dcls (e, xs) = calcPrec (\op x y -> PCon op $ ParPat . (:[]) <$> [x, y]) (getFixity dcls . snd) e xs

longPattern = parsePat PrecAnn <&> (getPVars &&& id)
--patternAtom = parsePat PrecAtom <&> (getPVars &&& id)

telescopePat = fmap (getPPVars . ParPat . map snd &&& id) $ many $ uncurry f <$> hiddenTerm (parsePat PrecAtom) (parsePat PrecAtom)
  where
    f h (PatType (ParPat [p]) t) = ((h, t), p)
    f h p = ((h, Wildcard SType), p)

checkPattern :: DBNames -> P ()
checkPattern ns = lift $ tell $ pure $ 
   case [ns' | ns' <- group . sort . filter (not . null . snd) $ ns
             , not . null . tail $ ns'] of
    [] -> Nothing
    xs -> Just $ "multiple pattern vars:\n" ++ unlines [n ++ " is defined at " ++ ppShow si | ns <- xs, (si, n) <- ns]


-------------------------------------------------------------------------------- pattern match compilation

data GuardTree
    = GuardNode SExp SName [ParPat] GuardTree -- _ <- _
    | Alts [GuardTree]          --      _ | _
    | GuardLeaf SExp            --     _ -> e
  deriving Show

alts (Alts xs) = concatMap alts xs
alts x = [x]

mapGT k i = \case
    GuardNode e c pps gt -> GuardNode (i k e) c {-todo: up-}pps $ mapGT (k + sum (map varPP pps)) i gt
    Alts gts -> Alts $ map (mapGT k i) gts
    GuardLeaf e -> GuardLeaf $ i k e

upGT k i = mapGT k $ \k -> up_ i k

substGT i j = mapGT 0 $ \k -> rearrangeS $ \r -> if r == k + i then k + j else if r > k + i then r - 1 else r
{-
dbfGT :: DBNames -> GuardTree -> GuardTree
dbfGT v = mapGT 0 $ \k -> dbf_ k v
-}
-- todo: clenup
compilePatts :: [(Pat, Int)] -> Either [(SExp, SExp)] SExp -> GuardTree
compilePatts ps gu = cp [] ps
  where
    cp ps' [] = case gu of
        Right e -> GuardLeaf $ rearrangeS (f $ reverse ps') e
        Left gs -> Alts
            [ GuardNode (rearrangeS (f $ reverse ps') ge) "True" [] $ GuardLeaf $ rearrangeS (f $ reverse ps') e
            | (ge, e) <- gs
            ]
    cp ps' ((p@PVar{}, i): xs) = cp (p: ps') xs
    cp ps' ((p@(PCon (si, n) ps), i): xs) = GuardNode (SVar (si, n) $ i + sum (map (fromMaybe 0 . ff) ps')) n ps $ cp (p: ps') xs
    cp ps' ((p@(ViewPat f (ParPat [PCon (si, n) ps])), i): xs)
        = GuardNode (SAppV f $ SVar (si, n) $ i + sum (map (fromMaybe 0 . ff) ps')) n ps $ cp (p: ps') xs

    m = length ps

    ff PVar{} = Nothing
    ff p = Just $ varP p

    f ps i
        | i >= s = i - s + m + sum vs'
        | i < s = case vs_ !! n of
        Nothing -> m + sum vs' - 1 - n
        Just _ -> m + sum vs' - 1 - (m + sum (take n vs') + j)
      where
        i' = s - 1 - i
        (n, j) = concat (zipWith (\k j -> zip (repeat j) [0..k-1]) vs [0..]) !! i'

        vs_ = map ff ps
        vs = map (fromMaybe 1) vs_
        vs' = map (fromMaybe 0) vs_
        s = sum vs

compileGuardTrees False ulend lend ge alts = compileGuardTree ulend lend ge $ Alts alts
compileGuardTrees True ulend lend ge alts = foldr1 (SAppV2 $ SBuiltin "parEval" `SAppV` Wildcard SType) $ compileGuardTree ulend lend ge <$> alts

compileGuardTree :: (SExp -> SExp) -> (SExp -> SExp) -> DesugarInfo -> GuardTree -> SExp
compileGuardTree ulend lend adts t = (\x -> traceD ("  !  :" ++ ppShow x) x) $ guardTreeToCases t
  where
    guardTreeToCases :: GuardTree -> SExp
    guardTreeToCases t = case alts t of
        [] -> ulend $ SBuiltin "undefined"
        GuardLeaf e: _ -> lend e
        ts@(GuardNode f s _ _: _) -> case Map.lookup s (snd adts) of
            Nothing -> error $ "Constructor is not defined: " ++ s
            Just (Left ((t, inum), cns)) ->
                foldl SAppV (SGlobal (debugSI "compileGuardTree2", caseName t) `SAppV` iterateN (1 + inum) SLamV (Wildcard SType))
                    [ iterateN n SLamV $ guardTreeToCases $ Alts $ map (filterGuardTree (up n f) cn 0 n . upGT 0 n) ts
                    | (cn, n) <- cns
                    ]
                `SAppV` f
            Just (Right n) -> SGlobal (debugSI "compileGuardTree3", MatchName s)
                `SAppV` SLamV (Wildcard SType)
                `SAppV` iterateN n SLamV (guardTreeToCases $ Alts $ map (filterGuardTree (up n f) s 0 n . upGT 0 n) ts)
                `SAppV` f
                `SAppV` guardTreeToCases (Alts $ map (filterGuardTree' f s) ts)

    filterGuardTree :: SExp -> SName{-constr.-} -> Int -> Int{-number of constr. params-} -> GuardTree -> GuardTree
    filterGuardTree f s k ns = \case
        GuardLeaf e -> GuardLeaf e
        Alts ts -> Alts $ map (filterGuardTree f s k ns) ts
        GuardNode f' s' ps gs
            | f /= f'  -> GuardNode f' s' ps $ filterGuardTree (up su f) s (su + k) ns gs
            | s == s'  -> filterGuardTree f s k ns $ guardNodes (zips [k+ns-1, k+ns-2..] ps) gs
            | otherwise -> Alts []
          where
            zips is ps = zip (map (SVar (debugSI "30", ".30")) $ zipWith (+) is $ sums $ map varPP ps) ps
            su = sum $ map varPP ps
            sums = scanl (+) 0

    filterGuardTree' :: SExp -> SName{-constr.-} -> GuardTree -> GuardTree
    filterGuardTree' f s = \case
        GuardLeaf e -> GuardLeaf e
        Alts ts -> Alts $ map (filterGuardTree' f s) ts
        GuardNode f' s' ps gs
            | f /= f' || s /= s' -> GuardNode f' s' ps $ filterGuardTree' (up su f) s gs
            | otherwise -> Alts []
          where
            su = sum $ map varPP ps

    guardNodes :: [(SExp, ParPat)] -> GuardTree -> GuardTree
    guardNodes [] l = l
    guardNodes ((v, ParPat ws): vs) e = guardNode v ws $ guardNodes vs e

    guardNode :: SExp -> [Pat] -> GuardTree -> GuardTree
    guardNode v [] e = e
    guardNode v [w] e = case w of
        PVar _ -> {-todo guardNode v (subst x v ws) $ -} varGuardNode 0 v e
        ViewPat f (ParPat p) -> guardNode (f `SAppV` v) p {- $ guardNode v ws -} e
        PCon (_, s) ps' -> GuardNode v s ps' {- $ guardNode v ws -} e

    varGuardNode v (SVar _ e) = substGT v e

compileCase ge x cs
    = SLamV (compileGuardTree id id ge $ Alts [compilePatts [(p, 0)] e | (p, e) <- cs]) `SAppV` x


-------------------------------------------------------------------------------- declaration representation

data Stmt
    = Let SIName MFixity (Maybe SExp) SExp
    | Data SIName [(Visibility, SExp)]{-parameters-} SExp{-type-} Bool{-True:add foralls-} [(SIName, SExp)]{-constructor names and types-}
    | PrecDef SIName Fixity

    -- eliminated during parsing
    | TypeFamily SIName [(Visibility, SExp)]{-parameters-} SExp{-type-}
    | Class SIName [SExp]{-parameters-} [(SIName, SExp)]{-method names and types-}
    | Instance SIName [Pat]{-parameter patterns-} [SExp]{-constraints-} [Stmt]{-method definitions-}
    | TypeAnn SIName SExp            -- intermediate
    | FunAlt SIName [((Visibility, SExp), Pat)] (Either [(SExp, SExp)]{-guards-} SExp{-no guards-})
    deriving (Show)

pattern Primitive n mf t <- Let n mf (Just t) (SBuiltin "undefined") where Primitive n mf t = Let n mf (Just t) $ SBuiltin "undefined"

-------------------------------------------------------------------------------- declaration parsing

parseDef :: P [Stmt]
parseDef =
     do reserved "data" *> do
            x <- typeNS upperCase
            (npsd, ts) <- telescope (Just SType)
            t <- dbf' npsd <$> parseType (Just SType)
            let mkConTy mk (nps', ts') =
                    ( if mk then Just nps' else Nothing
                    , foldr (uncurry SPi) (foldl SAppV (SGlobal x) $ downToS "a1" (length ts') $ length ts) ts')
            (af, cs) <- option (True, []) $
                 do fmap ((,) True) $ (reserved "where" >>) $ indentMS True $ second ((,) Nothing . dbf' npsd) <$> typedIds Nothing
             <|> (,) False <$ reservedOp "=" <*>
                      sepBy1 ((,) <$> (pure <$> upperCase)
                                  <*> do  do braces $ mkConTy True . second (zipWith (\i (v, e) -> (v, dbf_ i npsd e)) [0..])
                                                <$> telescopeDataFields
                                           <|> mkConTy False . second (zipWith (\i (v, e) -> (v, dbf_ i npsd e)) [0..])
                                                <$> telescope Nothing
                             )
                             (reservedOp "|")
            mkData <$> dsInfo <*> pure x <*> pure ts <*> pure t <*> pure af <*> pure (concatMap (\(vs, t) -> (,) <$> vs <*> pure t) cs)
 <|> do reserved "class" *> do
            x <- typeNS upperCase
            (nps, ts) <- telescope (Just SType)
            cs <- option [] $ (reserved "where" >>) $ indentMS True $ typedIds Nothing
            return $ pure $ Class x (map snd ts) (concatMap (\(vs, t) -> (,) <$> vs <*> pure (dbf' nps t)) cs)
 <|> do indentation (reserved "instance") $ typeNS $ do
            constraints <- option [] $ try "constraint" $ getTTuple' <$> parseTerm PrecOp <* reservedOp "=>"
            x <- upperCase
            (nps, args) <- telescopePat
            checkPattern nps            
            cs <- expNS $ option [] $ reserved "where" *> indentMS False (dbFunAlt nps <$> funAltDef varId)
            pure . Instance x ({-todo-}map snd args) (dbff (nps <> [x]) <$> constraints) <$> compileFunAlts' id{-TODO-} cs
 <|> do indentation (try "type family" $ reserved "type" >> reserved "family") $ typeNS $ do
            x <- upperCase
            (nps, ts) <- telescope (Just SType)
            t <- dbf' nps <$> parseType (Just SType)
            option {-open type family-}[TypeFamily x ts t] $ do
                cs <- (reserved "where" >>) $ indentMS True $ funAltDef $ mfilter (== x) upperCase
                -- closed type family desugared here
                compileFunAlts False id SLabelEnd [TypeAnn x $ addParamsS ts t] cs
 <|> do indentation (try "type instance" $ reserved "type" >> reserved "instance") $ typeNS $ pure <$> funAltDef upperCase
 <|> do indentation (reserved "type") $ typeNS $ do
            x <- upperCase
            (nps, ts) <- telescope $ Just (Wildcard SType)
            rhs <- dbf' nps <$ reservedOp "=" <*> parseTerm PrecLam
            compileFunAlts False id SLabelEnd
                [{-TypeAnn x $ addParamsS ts $ SType-}{-todo-}]
                [FunAlt x (zip ts $ map PVar $ reverse nps) $ Right rhs]
 <|> do try "typed ident" $ (\(vs, t) -> TypeAnn <$> vs <*> pure t) <$> typedIds Nothing
 <|> map (uncurry PrecDef) <$> parseFixityDecl
 <|> pure <$> funAltDef varId
 <|> valueDef
  where
    telescopeDataFields :: P ([SIName], [(Visibility, SExp)]) 
    telescopeDataFields = dbfi <$> commaSep ((,) Visible <$> ((,) <$> lowerCase <*> parseType Nothing))

    mkData ge x ts t af cs = Data x ts t af (second snd <$> cs): concatMap mkProj (nub $ concat [fs | (_, (Just fs, _)) <- cs])
      where
        mkProj fn
          = [ FunAlt fn [((Visible, Wildcard SType), PCon cn $ replicate (length fs) $ ParPat [PVar (mempty, "generated_name1")])] $ Right $ SVar (mempty, ".proj") i
            | (cn, (Just fs, _)) <- cs, (i, fn') <- zip [0..] fs, fn' == fn
            ]


parseRHS fe tok = fmap (fmap (fe *** fe) +++ fe) $ do
    fmap Left . some $ (,) <$ reservedOp "|" <*> parseTerm PrecOp <* reservedOp tok <*> parseTerm PrecLam
  <|> do
    reservedOp tok
    rhs <- parseTerm PrecLam
    f <- option id $ mkLets True <$ reserved "where" <*> dsInfo <*> parseDefs xSLabelEnd
    return $ Right $ f rhs

parseDefs lend = indentMS True parseDef >>= compileFunAlts' lend . concat

funAltDef parseName = do   -- todo: use ns to determine parseName
    (n, (fee, tss)) <-
        do try "operator definition" $ do
            (e', a1) <- longPattern
            n <- lhsOperator
            (e'', a2) <- longPattern
            lookAhead $ reservedOp "=" <|> reservedOp "|"
            return (n, (e'' <> e', (,) (Visible, Wildcard SType) <$> [a1, mapP (dbf' e') a2]))
      <|> do try "lhs" $ do
                n <- parseName
                (,) n <$> telescopePat <* lookAhead (reservedOp "=" <|> reservedOp "|")
    checkPattern fee
    FunAlt n tss <$> parseRHS (dbf' fee) "="

valueDef :: P [Stmt]
valueDef = do
    (dns, p) <- try "pattern" $ longPattern <* reservedOp "="
    checkPattern dns
    e <- parseETerm PrecLam
    ds <- dsInfo
    return $ desugarValueDef ds p e

desugarValueDef ds p e
    = FunAlt n [] (Right e)
    : [ FunAlt x [] $ Right $ compileCase ds (SGlobal n) [(p, Right $ SVar x i)]
      | (i, x) <- zip [0..] dns
      ]
  where
    dns = getPVars p
    n = mangleNames dns

mangleNames xs = (foldMap fst xs, "_" ++ intercalate "_" (map snd xs))
{-
parseSomeGuards f = do
    pos <- sourceColumn <$> getPosition <* reservedOp "|"
    guard $ f pos
    (e', f) <-
         do (e', PCon (_, p) vs) <- try "pattern" $ longPattern <* reservedOp "<-"
            checkPattern e'
            x <- parseETerm PrecOp
            return (e', \gs' gs -> GuardNode x p vs (Alts gs'): gs)
     <|> do x <- parseETerm PrecOp
            return (mempty, \gs' gs -> [GuardNode x "True" [] $ Alts gs', GuardNode x "False" [] $ Alts gs])
    f <$> ((map (dbfGT e') <$> parseSomeGuards (> pos)) <|> (:[]) . GuardLeaf <$ reservedOp "->" <*> (dbf' e' <$> parseETerm PrecLam))
      <*> option [] (parseSomeGuards (== pos))
-}
mkLets :: Bool -> DesugarInfo -> [Stmt]{-where block-} -> SExp{-main expression-} -> SExp{-big let with lambdas; replaces global names with de bruijn indices-}
mkLets a ds = mkLets' a ds . sortDefs ds where
    mkLets' _ _ [] e = e
    mkLets' False ge (Let n _ mt x: ds) e | not $ usedS n x
        = SLet (False, n) (maybe id (flip SAnn . addForalls {-todo-}[] []) mt x) (substSG0 n $ mkLets' False ge ds e)
    mkLets' True ge (Let n _ mt x: ds) e | not $ usedS n x
        = SLet (False, n) (maybe id (flip SAnn . addForalls {-todo-}[] []) mt x) (substSG0 n $ mkLets' True ge ds e)
    mkLets' _ _ (x: ds) e = error $ "mkLets: " ++ show x

xSLabelEnd = id --SLabelEnd

addForalls :: Up a => Extensions -> [SName] -> SExp' a -> SExp' a
addForalls exs defined x = foldl f x [v | v@(_, vh:_) <- reverse $ freeS x, snd v `notElem'` ("fromInt"{-todo: remove-}: defined), isLower vh || NoConstructorNamespace `elem` exs]
  where
    f e v = SPi Hidden (Wildcard SType) $ substSG0 v e

    notElem' s@('\'':s') m = notElem s m && notElem s' m
    notElem' s m = s `notElem` m
{-
defined defs = ("'Type":) $ flip foldMap defs $ \case
    TypeAnn (_, x) _ -> [x]
    Let (_, x) _ _ _ _  -> [x]
    Data (_, x) _ _ _ cs -> x: map (snd . fst) cs
    Class (_, x) _ cs    -> x: map (snd . fst) cs
    TypeFamily (_, x) _ _ -> [x]
    x -> error $ unwords ["defined: Impossible", show x, "cann't be here"]
-}

-------------------------------------------------------------------------------- declaration desugaring

sortDefs ds xs = concatMap (desugarMutual ds) $ topSort mempty mempty mempty nodes
  where
    nodes = zip (zip [0..] xs) $ map (def &&& need) xs
    need = \case
        PrecDef{} -> mempty
        Let _ _ mt e -> foldMap freeS' mt <> freeS' e
        Data _ ps t _ cs -> foldMap (freeS' . snd) ps <> freeS' t <> foldMap (freeS' . snd) cs
    def = \case
        PrecDef{} -> mempty
        Let n _ _ _ -> Set.singleton n
        Data n _ _ _ cs -> Set.singleton n <> Set.fromList (map fst cs)
    freeS' = Set.fromList . freeS
    topSort acc@(_:_) defs vs xs | Set.null vs = reverse acc: topSort mempty defs vs xs
    topSort [] _ vs [] | Set.null vs = []
    topSort acc defs vs (x@((i, v), (d, u)): ns)
        | i `elem` vs || all (`elem` defs) u = topSort (v: acc) (d <> defs) (Set.delete i vs) ns
        | otherwise = topSort acc defs (Set.insert i vs) $ let
                (ns1, ns2) = span (\(_, (d, _)) -> not $ Set.null $ d `Set.intersection` u) ns
            in ns1 ++ x: ns2

desugarMutual _ [x] = [x]
desugarMutual ds xs = xs
{-
    = FunAlt n [] (Right e)
    : [ FunAlt x [] $ Right $ compileCase ds (SGlobal n) [(p, Right $ SVar x i)]
      | (i, x) <- zip [0..] dns
      ]
  where
    dns = getPVars p
    n = mangleNames dns
    (ps, es) = unzip [(n, e) | Let n ~Nothing ~Nothing [] e <- xs]
    tup = "Tuple" ++ show (length xs)
    e = dbf' ps $ foldl SAppV (SBuiltin tup) es
    p = PCon (mempty, tup) $ map (ParPat . pure . PVar) ps
-}


compileFunAlts' lend ds = fmap concat . sequence $ map (compileFunAlts False lend lend ds) $ groupBy h ds where
    h (FunAlt n _ _) (FunAlt m _ _) = m == n
    h _ _ = False

--compileFunAlts :: forall m . Monad m => Bool -> (SExp -> SExp) -> (SExp -> SExp) -> DesugarInfo -> [Stmt] -> [Stmt] -> m [Stmt]
compileFunAlts par ulend lend ds xs = dsInfo >>= \ge -> case xs of
    [Instance{}] -> return []
    [Class n ps ms] -> do
        cd <- compileFunAlts' SLabelEnd $
            [ TypeAnn n $ foldr (SPi Visible) SType ps ]
         ++ [ FunAlt n (map noTA ps) $ Right $ foldr (SAppV2 $ SBuiltin "'T2") (SBuiltin "'Unit") cstrs | Instance n' ps cstrs _ <- ds, n == n' ]
         ++ [ FunAlt n (replicate (length ps) (noTA $ PVar (debugSI "compileFunAlts1", "generated_name0"))) $ Right $ SBuiltin "'Empty" `SAppV` sLit (LString $ "no instance of " ++ snd n ++ " on ???")]
        cds <- sequence
            [ compileFunAlts' SLabelEnd
            $ TypeAnn m (addParamsS (map ((,) Hidden) ps) $ SPi Hidden (foldl SAppV (SGlobal n) $ downToS "a2" 0 $ length ps) $ up1 t)
            : as
            | (m, t) <- ms
--            , let ts = fst $ getParamsS $ up1 t
            , let as = [ FunAlt m p $ Right {- $ SLam Hidden (Wildcard SType) $ up1 -} e
                      | Instance n' i cstrs alts <- ds, n' == n
                      , Let m' ~Nothing ~Nothing e <- alts, m' == m
                      , let p = zip ((,) Hidden <$> ps) i ++ [((Hidden, Wildcard SType), PVar (mempty, ""))]
        --              , let ic = sum $ map varP i
                      ]
            ]
        return $ cd ++ concat cds
    [TypeAnn n t] -> return [Primitive n Nothing t | snd n `notElem` [n' | FunAlt (_, n') _ _ <- ds]]
    tf@[TypeFamily n ps t] -> case [d | d@(FunAlt n' _ _) <- ds, n' == n] of
        [] -> return [Primitive n Nothing $ addParamsS ps t]
        alts -> compileFunAlts True id SLabelEnd [TypeAnn n $ addParamsS ps t] alts
    [p@PrecDef{}] -> return [p]
    fs@(FunAlt n vs _: _) -> case map head $ group [length vs | FunAlt _ vs _ <- fs] of
        [num]
          | num == 0 && length fs > 1 -> fail $ "redefined " ++ snd n ++ " at " ++ ppShow (fst n)
          | n `elem` [n' | TypeFamily n' _ _ <- ds] -> return []
          | otherwise -> return
            [ Let n
                (listToMaybe [t | PrecDef n' t <- ds, n' == n])
                (listToMaybe [t | TypeAnn n' t <- ds, n' == n])
                $ foldr (uncurry SLam . fst) (compileGuardTrees par ulend lend ge
                    [ compilePatts (zip (map snd vs) $ reverse [0.. num - 1]) gsx
                    | FunAlt _ vs gsx <- fs
                    ]) vs
            ]
        _ -> fail $ "different number of arguments of " ++ snd n ++ " at " ++ ppShow (fst n)
    x -> return x
  where
    noTA x = ((Visible, Wildcard SType), x)

dbFunAlt v (FunAlt n ts gue) = FunAlt n (map (second $ mapP (dbf' v)) ts) $ fmap (dbf' v *** dbf' v) +++ dbf' v $ gue


-------------------------------------------------------------------------------- desugar info

mkDesugarInfo :: [Stmt] -> DesugarInfo
mkDesugarInfo ss =
    ( Map.fromList $ ("'EqCTt", (Infix, -1)): [(s, f) | PrecDef (_, s) f <- ss]
    , Map.fromList $
        [(cn, Left ((t, pars ty), (snd *** pars) <$> cs)) | Data (_, t) ps ty _ cs <- ss, ((_, cn), ct) <- cs]
     ++ [(t, Right $ pars $ addParamsS ps ty) | Data (_, t) ps ty _ _ <- ss]
--     ++ [(t, Right $ length xs) | Let (_, t) _ (Just ty) xs _ <- ss]
     ++ [("'Type", Right 0)]
    )
  where
    pars ty = length $ filter ((== Visible) . fst) $ fst $ getParamsS ty -- todo

joinDesugarInfo (fm, cm) (fm', cm') = (Map.union fm fm', Map.union cm cm')


-------------------------------------------------------------------------------- module exports

data Export = ExportModule SIName | ExportId SIName

parseExport :: Namespace -> P Export
parseExport ns =
        ExportModule <$ reserved "module" <*> moduleName
    <|> ExportId <$> varId

-------------------------------------------------------------------------------- module imports

data ImportItems
    = ImportAllBut [SIName]
    | ImportJust [SIName]

importlist = parens $ commaSep upperLower

-------------------------------------------------------------------------------- language pragmas

type Extensions = [Extension]

data Extension
    = NoImplicitPrelude
    | NoTypeNamespace
    | NoConstructorNamespace
    | TraceTypeCheck
    deriving (Enum, Eq, Ord, Show)

extensionMap :: Map.Map String Extension
extensionMap = Map.fromList $ map (show &&& id) [toEnum 0 .. ]

parseExtensions :: P [Extension]
parseExtensions
    = try "pragma" (symbol "{-#") *> symbol "LANGUAGE" *> commaSep (lexeme ext) <* symbol' simpleSpace "#-}"
  where
    ext = do
        s <- some $ satisfy isAlphaNum
        maybe
          (fail $ "language extension expected instead of " ++ s)
          return
          (Map.lookup s extensionMap)

-------------------------------------------------------------------------------- modules

data Module
  = Module
  { extensions    :: Extensions
  , moduleImports :: [(SIName, ImportItems)]
  , moduleExports :: Maybe [Export]
  , definitions   :: DefParser
  }

type DefParser = DesugarInfo -> (Either ParseError [Stmt], [PostponedCheck])

parseModule :: FilePath -> String -> P Module
parseModule f str = do
    exts <- concat <$> many parseExtensions
    let ns = Namespace (if NoTypeNamespace `elem` exts then Nothing else Just ExpLevel) (NoConstructorNamespace `notElem` exts)
    whiteSpace
    header <- optional $ do
        modn <- reserved "module" *> moduleName
        exps <- optional (parens $ commaSep $ parseExport ns)
        reserved "where"
        return (modn, exps)
    let mkIDef _ n i h _ = (n, f i h)
          where
            f Nothing Nothing = ImportAllBut []
            f (Just h) Nothing = ImportAllBut h
            f Nothing (Just i) = ImportJust i
    idefs <- many $
          mkIDef <$  reserved "import"
                 <*> optional (reserved "qualified")
                 <*> moduleName
                 <*> optional (reserved "hiding" *> importlist)
                 <*> optional importlist
                 <*> optional (reserved "as" *> moduleName)
    st <- getParserState
    return Module
      { extensions    = exts
      , moduleImports = [((mempty, "Prelude"), ImportAllBut []) | NoImplicitPrelude `notElem` exts] ++ idefs
      , moduleExports = join $ snd <$> header
      , definitions   = \ge -> first snd $ runP' (ge, ns) f (parseDefs SLabelEnd <* eof) st
      }

parseLC :: FilePath -> String -> Either ParseError Module
parseLC f str
    = fst
    . runP (error "globalenv used", Namespace (Just ExpLevel) True) f (parseModule f str)
    $ str

--type DefParser = DesugarInfo -> (Either ParseError [Stmt], [PostponedCheck])
runDefParser :: (MonadFix m, MonadError String m) => DesugarInfo -> DefParser -> m [Stmt]
runDefParser ds_ dp = do

    ((defs, dns), ds) <- mfix $ \ ~(_, ds) -> do
        let (x, dns) = dp ds
        defs <- either (throwError . show) return x
        let ds' = mkDesugarInfo defs `joinDesugarInfo` ds_
        return ((defs, dns), ds')

    mapM_ (maybe (return ()) throwError) dns

    return $ sortDefs ds defs


-------------------------------------------------------------------------------- pretty print

instance Up a => PShow (SExp' a) where
    pShowPrec _ = showDoc_ . sExpDoc

type Doc = NameDB PrecString

-- name De Bruijn indices
type NameDB a = StateT [String] (Reader [String]) a

showDoc :: Doc -> String
showDoc = str . flip runReader [] . flip evalStateT (flip (:) <$> iterate ('\'':) "" <*> ['a'..'z'])

showDoc_ :: Doc -> P.Doc
showDoc_ = text . str . flip runReader [] . flip evalStateT (flip (:) <$> iterate ('\'':) "" <*> ['a'..'z'])

sExpDoc :: Up a => SExp' a -> Doc
sExpDoc = \case
    SGlobal (_,s)   -> pure $ shAtom s
    SAnn a b        -> shAnn ":" False <$> sExpDoc a <*> sExpDoc b
    TyType a        -> shApp Visible (shAtom "tyType") <$> sExpDoc a
    SApp _ h a b    -> shApp h <$> sExpDoc a <*> sExpDoc b
    Wildcard t      -> shAnn ":" True (shAtom "_") <$> sExpDoc t
    SBind _ h _ a b -> join $ shLam (used 0 b) h <$> sExpDoc a <*> pure (sExpDoc b)
    SLet _ a b      -> shLet_ (sExpDoc a) (sExpDoc b)
    STyped _ _{-(e,t)-}  -> pure $ shAtom "<<>>" -- todo: expDoc e
    SVar _ i        -> shAtom <$> shVar i
    SLit _ l        -> pure $ shAtom $ show l

shVar i = asks lookupVarName where
    lookupVarName xs | i < length xs && i >= 0 = xs !! i
    lookupVarName _ = "V" ++ show i

newName = gets head <* modify tail

shLet i a b = shAtom <$> shVar i >>= \i' -> local (dropNth i) $ shLam' <$> (cpar . shLet' (fmap inBlue i') <$> a) <*> b
shLet_ a b = newName >>= \i -> shLam' <$> (cpar . shLet' (shAtom i) <$> a) <*> local (i:) b
shLam used h a b = newName >>= \i ->
    let lam = case h of
            BPi _ -> shArr
            _ -> shLam'
        p = case h of
            BMeta -> cpar . shAnn ":" True (shAtom $ inBlue i)
            BLam h -> vpar h
            BPi h -> vpar h
        vpar Hidden = brace . shAnn ":" True (shAtom $ inGreen i)
        vpar Visible = ann (shAtom $ inGreen i)
        ann | used = shAnn ":" False
            | otherwise = const id
    in lam (p a) <$> local (i:) b

-----------------------------------------

data PS a = PS Prec a deriving (Functor)
type PrecString = PS String

getPrec (PS p _) = p
prec i s = PS i (s i)
str (PS _ s) = s

lpar, rpar :: PrecString -> Prec -> String
lpar (PS i s) j = par (i >. j) s  where
    PrecLam >. i = i > PrecAtom'
    i >. PrecLam = i >= PrecArr
    PrecApp >. PrecApp = False
    i >. j  = i >= j
rpar (PS i s) j = par (i >. j) s where
    PrecLam >. PrecLam = False
    PrecLam >. i = i > PrecAtom'
    PrecArr >. PrecArr = False
    PrecAnn >. PrecAnn = False
    i >. j  = i >= j

par True s = "(" ++ s ++ ")"
par False s = s

isAtom = (==PrecAtom) . getPrec
isAtom' = (<=PrecAtom') . getPrec

shAtom = PS PrecAtom
shAtom' = PS PrecAtom'
shAnn _ True x y | str y `elem` ["Type", inGreen "Type"] = x
shAnn s simp x y | isAtom x && isAtom y = shAtom' $ str x <> s <> str y
shAnn s simp x y = prec PrecAnn $ lpar x <> " " <> const s <> " " <> rpar y
shApp Hidden x y = prec PrecApp $ lpar x <> " " <> const (str $ brace y)
shApp h x y = prec PrecApp $ lpar x <> " " <> rpar y
shArr x y | isAtom x && isAtom y = shAtom' $ str x <> "->" <> str y
shArr x y = prec PrecArr $ lpar x <> " -> " <> rpar y
shCstr x y | isAtom x && isAtom y = shAtom' $ str x <> "~" <> str y
shCstr x y = prec PrecEq $ lpar x <> " ~ " <> rpar y
shLet' x y | isAtom x && isAtom y = shAtom' $ str x <> ":=" <> str y
shLet' x y = prec PrecLet $ lpar x <> " := " <> rpar y
shLam' x y | PrecLam <- getPrec y = prec PrecLam $ "\\" <> lpar x <> " " <> pure (dropC $ str y)
  where
    dropC (ESC s (dropC -> x)) = ESC s x
    dropC (x: xs) = xs
shLam' x y | isAtom x && isAtom y = shAtom' $ "\\" <> str x <> "->" <> str y
shLam' x y = prec PrecLam $ "\\" <> lpar x <> " -> " <> rpar y
brace s = shAtom $ "{" <> str s <> "}"
cpar s | isAtom' s = s      -- TODO: replace with lpar, rpar
cpar s = shAtom $ par True $ str s
epar = fmap underlined

instance IsString (Prec -> String) where fromString = const

