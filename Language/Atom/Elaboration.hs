-- |
-- Module: Elaboration
-- Description: -
-- Copyright: (c) 2013 Tom Hawkins & Lee Pike

module Language.Atom.Elaboration
  (
  -- * Atom monad and container.
    Atom
  , AtomDB   (..)
  , Global   (..)
  , Rule     (..)
  , ChanInfo (..)
  , StateHierarchy (..)
  , buildAtom
  -- * Type Aliases and Utilities
  , Phase (..)
  , elaborate
  , var
  , var'
  , array
  , array'
  , addName
  , get
  , put
  , allUVs
  , allUEs
  , isHierarchyEmpty
  ) where

import Control.Monad (ap)
import qualified Control.Monad.State.Strict as S
import Control.Monad.Trans

import Data.Function (on)
import Data.Char (isAlpha, isAlphaNum)
import Data.List (intercalate, nub, sort)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (isJust, isNothing)

import Language.Atom.Types
import Language.Atom.Channel.Types
import Language.Atom.Expressions hiding (typeOf)
import Language.Atom.UeMap


data Global = Global
  { gRuleId    :: Int
  , gVarId     :: Int
  , gArrayId   :: Int
  , gChannelId :: Int
  , gState     :: [StateHierarchy]
  , gProbes    :: [(String, Hash)]
  , gPeriod    :: Int
  , gPhase     :: Phase
  }
  deriving (Show)

initialGlobal :: Global
initialGlobal = Global
  { gRuleId    = 0
  , gVarId     = 0
  , gArrayId   = 0
  , gChannelId = 0
  , gState     = []
  , gProbes    = []
  , gPeriod    = 1
  , gPhase     = MinPhase 0
  }

data AtomDB = AtomDB
  { atomId          :: Int
  , atomName        :: Name
    -- | Names used at this level.
  , atomNames       :: [Name]
    -- | Enabling condition.
  , atomEnable      :: Hash
    -- | Non-hereditary component on enable cond
  , atomEnableNH    :: Hash
    -- | Sub atoms.
  , atomSubs        :: [AtomDB]
  , atomPeriod      :: Int
  , atomPhase       :: Phase
    -- | Sequence of (variable, shared expr) assignments arising from '<=='
  , atomAssigns     :: [(MUV, Hash)]
  , atomActions     :: [([String] -> String, [Hash])]
  , atomAsserts     :: [(Name, Hash)]
  , atomCovers      :: [(Name, Hash)]
    -- | a list of (channel input, channel value hash) pairs for writes
  , atomChanWrite   :: [(ChanInput, Hash, ChannelDelay)]
  , atomChanRead    :: [ChanOutput]
  }

instance Show AtomDB where
  show a = "AtomDB { " ++ intercalate ", " [ show (atomId a)
                                           , atomName a
                                           -- , show (atomEnable a)
                                           -- , show (atomEnableNH a)
                                           ] ++ " }"  -- TODO more detail?
instance Eq   AtomDB where (==) = (==) `on` atomId
instance Ord  AtomDB where compare a b = compare (atomId a) (atomId b)

-- XXX sum of records leads to partial record field functions
data Rule
  = Rule
    { ruleId          :: Int
    , ruleName        :: Name
    , ruleEnable      :: Hash
    , ruleEnableNH    :: Hash
    , ruleAssigns     :: [(MUV, Hash)]
    , ruleActions     :: [([String] -> String, [Hash])]
    , rulePeriod      :: Int
    , rulePhase       :: Phase
    , ruleChanWrite   :: [(ChanInput, Hash, ChannelDelay)]
      -- ^ see corresonding field in AtomDB
    , ruleChanRead    :: [ChanOutput]
    }
  | Assert
    { ruleName      :: Name
    , ruleEnable    :: Hash
    , ruleAssert    :: Hash
    }
  | Cover
    { ruleName      :: Name
    , ruleEnable    :: Hash
    , ruleCover     :: Hash
    }

instance Show Rule where
  show r@Rule{} = "Rule { " ++ intercalate ", " [ show (ruleId r)
                                                , ruleName r
                                                -- , show (ruleEnable r)
                                                -- , show (ruleEnableNH r)
                                                ] ++ " }"  -- TODO more detail?
  show _r@Assert{} = "Assert{}"
  show _r@Cover{} = "Cover{}"

-- | Compiled channel info used to return channel info from the elaboration
-- functions.
data ChanInfo = ChanInfo
  { cinfoSrc       :: Maybe Int   -- ^ ruleId of source, either this or next is set
  , cinfoRecv      :: Maybe Int   -- ^ ruleId of receiver
  , cinfoId        :: Int         -- ^ internal channel ID
  , cinfoName      :: Name        -- ^ user supplied channel name
  , cinfoType      :: Type        -- ^ channel type
  , cinfoValueExpr :: Maybe Hash  -- ^ hash to channel value expression, may
  }                               --   or may not be set
  deriving (Eq, Show)

data StateHierarchy
  = StateHierarchy Name [StateHierarchy]
  | StateVariable  Name Const
  | StateArray     Name [Const]
  | StateChannel   Name Type
  deriving (Show)


elaborateRules :: Hash -> AtomDB -> UeState [Rule]
elaborateRules parentEnable atom =
      if isRule then do r  <- rule
                        rs <- rules
                        return (r : rs)
                 else rules
  where
    -- are there either assignments, actions, or writeChannels to be done?
    isRule = not $ null (atomAssigns atom)
                     && null (atomActions atom)
                     && null (atomChanWrite atom)

    -- combine the parent enable and the child enable conditions
    enable :: UeState Hash
    enable = do
      st <- S.get
      let (h,st') = newUE (uand (recoverUE st parentEnable)
                                (recoverUE st (atomEnable atom)))
                           st
      S.put st'
      return h

    -- *don't* combine the parent enableNH and the child enableNH conditions
    enableNH :: UeState Hash
    enableNH = do
      return (atomEnableNH atom)

    -- creat a 'Rule' from the 'AtomDB' and enable condition(s)
    rule :: UeState Rule
    rule = do
      h <- enable
      h' <- enableNH
      assigns <- S.foldM (\prs pr -> do pr' <- enableAssign pr
                                        return $ pr' : prs) []
                         (atomAssigns atom)
      return Rule
        { ruleId         = atomId   atom
        , ruleName       = atomName atom
        , ruleEnable     = h
        , ruleEnableNH   = h'
        , ruleAssigns    = assigns
        , ruleActions    = atomActions atom
        , rulePeriod     = atomPeriod  atom
        , rulePhase      = atomPhase   atom
        , ruleChanWrite  = atomChanWrite atom
        , ruleChanRead = atomChanRead atom
        }

    assert :: (Name, Hash) -> UeState Rule
    assert (name, u) = do
      h <- enable
      return Assert
        { ruleName      = name
        , ruleEnable    = h
        , ruleAssert    = u
        }

    cover :: (Name, Hash) -> UeState Rule
    cover (name, u) = do
      h <- enable
      return Cover
        { ruleName      = name
        , ruleEnable    = h
        , ruleCover     = u
        }

    -- essentially maps 'ellaborateRules' over the asserts, covers, and
    -- subatoms in the given 'AtomDB'
    rules :: UeState [Rule]
    rules = do
      asserts <- S.foldM (\rs e -> do r <- assert e
                                      return (r:rs)
                         ) [] (atomAsserts atom)
      covers  <- S.foldM (\rs e -> do r <- cover e
                                      return (r:rs)
                         ) [] (atomCovers atom)
      rules'  <- S.foldM (\rs db -> do en <- enable
                                       r <- elaborateRules en db
                                       return (r:rs)
                         ) [] (atomSubs atom)
      return $ asserts ++ covers ++ concat rules'

    -- push the enable condition into each assignment. In the code generator
    -- this results in assignments like @uint64_t __6 = __0 ? __5 : __3;@
    -- where @__0@ is the 'enable' condition.
    enableAssign :: (MUV, Hash) -> UeState (MUV, Hash)
    enableAssign (uv', ue') = do
      e   <- enable
      enh <- enableNH
      h   <- maybeUpdate (MUVRef uv')  -- insert variable into the UE map
      st  <- S.get
      -- conjoin the regular enable condition and the non-inherited one,
      -- creating a new UE in the process
      let andes = uand (recoverUE st e) (recoverUE st enh)
          (e', st') = newUE andes st
      S.put st'
      let muxe      = umux (recoverUE st' e') (recoverUE st' ue') (recoverUE st' h)
          (h',st'') = newUE muxe st'
      S.put st''
      return (uv', h')

reIdRules :: Int -> [Rule] -> [Rule]
reIdRules _ [] = []
reIdRules i (a:b) = case a of
  Rule{} -> a { ruleId = i } : reIdRules (i + 1) b
  _      -> a                : reIdRules  i      b

-- | Get a list of all channels written to in the given list of rules.
getChannels :: [Rule] -> Map Int ChanInfo
getChannels rs = Map.unionsWith mergeInfo (map getChannels' rs)
  where getChannels' :: Rule -> Map Int ChanInfo
        getChannels' r@Rule{} =
          -- TODO: fwrite and fread could be refactored in more concise way
          let fwrite :: (ChanInput, Hash, ChannelDelay) -> (Int, ChanInfo)
              fwrite (c, h, _) = ( chanID c
                                 , ChanInfo
                                     { cinfoSrc       = Just (ruleId r)
                                     , cinfoRecv      = Nothing
                                     , cinfoId        = chanID c
                                     , cinfoName      = chanName c
                                     , cinfoType      = chanType c
                                     , cinfoValueExpr = Just h
                                     }
                                 )
              fread :: ChanOutput -> (Int, ChanInfo)
              fread c = ( chanID c
                        , ChanInfo
                            { cinfoSrc       = Nothing
                            , cinfoRecv      = Just (ruleId r)
                            , cinfoId        = chanID c
                            , cinfoName      = chanName c
                            , cinfoType      = chanType c
                            , cinfoValueExpr = Nothing
                            }
                        )
          in Map.fromList (map fwrite (ruleChanWrite r)
                           ++ map fread (ruleChanRead r))
        getChannels' _ = Map.empty  -- asserts and coverage statements have no channels

        -- Merge two channel info records, in particular this unions the
        -- `cinfoSrc` fields and also the `cinfoRecv` fields.
        mergeInfo :: ChanInfo -> ChanInfo -> ChanInfo
        mergeInfo c1 c2 =
          if (cinfoId c1 == cinfoId c2) &&      -- check invariant
             (cinfoName c1 == cinfoName c2) &&
             (cinfoType c1 == cinfoType c2) &&
             ((cinfoValueExpr c1 == cinfoValueExpr c2) ||  -- either equal or
              (isNothing (cinfoValueExpr c1)) ||           -- one is a Nothing
              (isNothing (cinfoValueExpr c2)))
             then c1 -- { cinfoSrc = cinfoSrc c1 `union` cinfoSrc c2
                     -- , cinfoRecv = cinfoRecv c1 `union` cinfoRecv c2
                     { cinfoSrc = muxMaybe (cinfoSrc c1) (cinfoSrc c2)
                     , cinfoRecv = muxMaybe (cinfoRecv c1) (cinfoRecv c2)
                     , cinfoValueExpr = muxMaybe (cinfoValueExpr c1)
                                                 (cinfoValueExpr c2)
                     }
             else error "Elaboration: getChannels: mismatch occured"

buildAtom :: UeMap -> Global -> Name -> Atom a -> IO (a, AtomSt)
buildAtom st g name (Atom f) = do
  let (h,st') = newUE (ubool True) st
  let (h',st'') = newUE (ubool True) st'
  f (st'', ( g { gRuleId = gRuleId g + 1 }
          , AtomDB
              { atomId        = gRuleId g
              , atomName      = name
              , atomNames     = []
              , atomEnable    = h
              , atomEnableNH  = h'
              , atomSubs      = []
              , atomPeriod    = gPeriod g
              , atomPhase     = gPhase  g
              , atomAssigns   = []
              , atomActions   = []
              , atomAsserts   = []
              , atomCovers    = []
              , atomChanWrite = []
              , atomChanRead  = []
              }
          )
    )

type AtomSt = (UeMap, (Global, AtomDB))

-- | The Atom monad holds variable and rule declarations.
data Atom a = Atom (AtomSt -> IO (a, AtomSt))

instance Applicative Atom where
  pure = return
  (<*>) = ap

instance Functor Atom where
  fmap = S.liftM

instance Monad Atom where
  return a = Atom (\ s -> return (a, s))
  (Atom f1) >>= f2 = Atom f3
    where
    f3 s = do
      (a, s') <- f1 s
      let Atom f4 = f2 a
      f4 s'

instance MonadIO Atom where
  liftIO io = Atom f
    where
    f s = do
      a <- io
      return (a, s)

get :: Atom AtomSt
get = Atom (\ s -> return (s, s))

put :: AtomSt -> Atom ()
put s = Atom (\ _ -> return ((), s))


-- | Given a top level name and design, elaborates design and returns a design
-- database.
--
-- XXX elaborate is a bit hacky since we're threading state through this
-- function, but I don't want to go change all the UeState monads to UeStateT
-- monads.
--
elaborate :: UeMap -> Name -> Atom ()
          -> IO (Maybe ( UeMap
                       , (  StateHierarchy, [Rule], [ChanInfo], [Name], [Name]
                         , [(Name, Type)])
                       ))
elaborate st name atom = do
  (_, (st0, (g, atomDB))) <- buildAtom st initialGlobal name atom
  let (h, st1)        = newUE (ubool True) st0
      (getRules, st2) = S.runState (elaborateRules h atomDB) st1
      rules           = reIdRules 0 (reverse getRules)
      -- channel source and dest are numbered based on 'ruleId's in 'rules'
      channels        = Map.elems (getChannels rules)
      coverageNames   = [ name' | Cover  name' _ _ <- rules ]
      assertionNames  = [ name' | Assert name' _ _ <- rules ]
      probeNames      = [ (n, typeOf a st2) | (n, a) <- gProbes g ]
  if null rules
    then do
      putStrLn "ERROR: Design contains no rules.  Nothing to do."
      return Nothing
    else do
      mapM_ (checkEnable st2) rules
      oks <- mapM checkAssignConflicts rules
      return $ if and oks
                 then Just ( st2
                           , ( trimState . StateHierarchy name $ gState g
                             , rules
                             , channels
                             , assertionNames
                             , coverageNames
                             , probeNames
                             )
                           )
                 else Nothing

trimState :: StateHierarchy -> StateHierarchy
trimState a =
    case a of
      StateHierarchy name items ->
        StateHierarchy name (filter f . map trimState $ items)
      a' -> a'
  where
    f (StateHierarchy _ []) = False
    f _ = True

-- | Check if state hierarchy is empty
isHierarchyEmpty :: StateHierarchy -> Bool
isHierarchyEmpty h = case h of
  StateHierarchy _ []  -> True
  StateHierarchy _ i   -> all isHierarchyEmpty i
  StateVariable  _ _   -> False
  StateArray     _ _   -> False
  StateChannel   _ _   -> False

-- | Checks that a rule will not be trivially disabled.
checkEnable :: UeMap -> Rule -> IO ()
checkEnable st rule
  | let f = (fst $ newUE (ubool False) st) in
    ruleEnable rule == f || ruleEnableNH rule == f
    = putStrLn $ "WARNING: Rule will never execute: " ++ show rule
  | otherwise = return ()

-- | Check that a variable is assigned more than once in a rule.  Will
-- eventually be replaced consistent assignment checking.
checkAssignConflicts :: Rule -> IO Bool
checkAssignConflicts rule@Rule{} =
  if length vars /= length vars'
    then do
      putStrLn $ "ERROR: Rule "
                   ++ show rule
                   ++ " contains multiple assignments to the same variable(s)."
      return False
    else
      return True
  where
  vars = map fst (ruleAssigns rule)
  vars' = nub vars
checkAssignConflicts _ = return True

-- | Generic local variable declaration.
var :: Expr a => Name -> a -> Atom (V a)
var name init' = do
  name' <- addName name
  (st, (g, atom)) <- get
  let uv' = UV (gVarId g) name' c
      c = constant init'
  put (st, ( g { gVarId = gVarId g + 1
               , gState = gState g ++ [StateVariable name c]
               }
           , atom
           )
      )
  return $ V uv'

-- | Generic external variable declaration.
var' :: Name -> Type -> V a
var' name t = V $ UVExtern name t

-- | Generic array declaration.
array :: Expr a => Name -> [a] -> Atom (A a)
array name [] = error $ "ERROR: arrays can not be empty: " ++ name
array name init' = do
  name' <- addName name
  (st, (g, atom)) <- get
  let ua = UA (gArrayId g) name' c
      c = map constant init'
  put (st, ( g { gArrayId = gArrayId g + 1
               , gState = gState g ++ [StateArray name c]
               }
           , atom
           )
      )
  return $ A ua

-- | Generic external array declaration.
array' :: Name -> Type -> A a
array' name t = A $ UAExtern  name t

-- | Add a name to the AtomDB and check that it is unique, throws an exception
-- if not.
--
-- Note: the name returned is prefixed with the state hierarchy selector.
addName :: Name -> Atom Name
addName name = do
  (st, (g, atom)) <- get
  checkName name
  if name `elem` atomNames atom
    then error $ unwords [ "ERROR: Name \"" ++ name ++ "\" not unique in"
                         , show atom ++ "." ]
    else do
      put (st, (g, atom { atomNames = name : atomNames atom }))
      return $ atomName atom ++ "." ++ name

-- still accepts some malformed names, like "_.." or "_]["
checkName :: Name -> Atom ()
checkName name =
  if (\ x -> isAlpha x || x == '_') (head name) &&
      all (\ x -> isAlphaNum x || x `elem` "._[]") (tail name)
    then return ()
    else error $ "ERROR: Name \"" ++ name ++ "\" is not a valid identifier."

-- | All the variables that directly and indirectly control the value of an expression.
allUVs :: UeMap -> [Rule] -> Hash -> [MUV]
allUVs st rules ue' = fixedpoint next $ nearestUVs ue' st
  where
  assigns = concat [ ruleAssigns r | r@Rule{} <- rules ]
  previousUVs :: MUV -> [MUV]
  previousUVs u = concat [ nearestUVs ue_ st | (uv', ue_) <- assigns, u == uv' ]
  next :: [MUV] -> [MUV]
  next uvs = sort $ nub $ uvs ++ concatMap previousUVs uvs

-- | Apply the function until a fixedpoint is found. Why is this not in
-- Prelude?
fixedpoint :: Eq a => (a -> a) -> a -> a
fixedpoint f a | a == f a  = a
               | otherwise = fixedpoint f $ f a

-- | All primary expressions used in a rule.
allUEs :: Rule -> [Hash]
allUEs rule = ruleEnable rule : ruleEnableNH rule : ues
  where
  index :: MUV -> [Hash]
  index (MUVArray _ ue') = [ue']
  index _ = []
  ues = case rule of
    Rule{} ->
         concat [ ue' : index uv' | (uv', ue') <- ruleAssigns rule ]
      ++ concatMap snd (ruleActions rule)
      ++ map (\(_, h, _) -> h) (ruleChanWrite rule)
    Assert _ _ a       -> [a]
    Cover  _ _ a       -> [a]

-- | Left biased combination of maybe values. `muxMaybe` has the property that
-- if one of the two inputs is a `Just`, then the output will also be.
muxMaybe :: Maybe a -> Maybe a -> Maybe a
muxMaybe x y = if isJust x then x
                           else y
