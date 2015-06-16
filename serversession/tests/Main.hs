module Main (main) where

import Control.Applicative ((<$), (<$>), (<*>))
import Control.Arrow
import Control.Monad
import Data.Maybe
import Data.Typeable (Typeable)
import Test.Hspec
import Test.Hspec.QuickCheck
import Web.PathPieces
import Web.ServerSession.Core.Internal
import Web.ServerSession.Core.StorageTests

import qualified Control.Exception as E
import qualified Crypto.Nonce as N
import qualified Data.ByteString.Char8 as B8
import qualified Data.HashMap.Strict as HM
import qualified Data.IORef as I
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Time as TI
import qualified Test.QuickCheck.Property as Q


main :: IO ()
main = hspec $ parallel $ do
  -- State using () as storage.  As () is not a Storage instance,
  -- this is the state to be used when testing functions that
  -- should not touch the storage in any code path.
  stnull <- runIO $ createState ()

  -- State using TNTStorage.  This state should be used for
  -- functions that normally need to access the storage but on
  -- the test code path should not do so.
  sttnt <- runIO $ createState TNTStorage

  -- Some functions take a time argument meaning "now".  We don't
  -- gain anything using real "now", so here's a fake "now".
  let fakenow = read "2015-05-27 17:55:41 UTC" :: TI.UTCTime

  describe "SessionId" $ do
    gen <- runIO N.new
    it "is generated with 24 bytes from letters, numbers, dashes and underscores" $ do
      let reps = 10000
      sids <- replicateM reps (generateSessionId gen)
      -- Test length to be 24 bytes.
      map (T.length . unS) sids `shouldBe` replicate reps 24
      -- Test that we see all chars, and only the expected ones.
      -- The probability of a given character not appearing on
      -- this test is (63/64)^(24*reps), so it's extremely
      -- unlikely for this test to fail on correct code.
      let observed = S.fromList $ concat $ T.unpack . unS <$> sids
          expected = S.fromList $ ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ "-_"
      observed `shouldBe` expected

    prop "accepts as valid the session IDs generated by ourselves" $
      Q.ioProperty $ do
        sid <- generateSessionId gen
        return $ fromPathPiece (toPathPiece sid) Q.=== Just sid

    it "does not accept as valid some example invalid session IDs" $ do
      let parse = fromPathPiece :: T.Text -> Maybe (SessionId SessionMap)
      parse ""                          `shouldBe` Nothing
      parse "123456789-123456789-123"   `shouldBe` Nothing
      parse "123456789-123456789-12345" `shouldBe` Nothing
      parse "aaaaaaaaaaaaaaaaaa*aaaaa"  `shouldBe` Nothing
      -- sanity check
      parse "123456789-123456789-1234"  `shouldSatisfy` isJust
      parse "aaaaaaaaaaaaaaaaaaaaaaaa"  `shouldSatisfy` isJust

  describe "State" $ do
    it "has the expected default values" $ do
      -- A silly test to avoid unintended change of default values.
      cookieName stnull        `shouldBe` "JSESSIONID"
      authKey stnull           `shouldBe` "_ID"
      idleTimeout stnull       `shouldBe` Just (60*60*24*7)
      absoluteTimeout stnull   `shouldBe` Just (60*60*24*60)
      timeoutResolution stnull `shouldBe` Just (60*10)
      persistentCookies stnull `shouldBe` True
      httpOnlyCookies stnull   `shouldBe` True
      secureCookies stnull     `shouldBe` False

    it "has sane setters of ambiguous types" $ do
      cookieName        (setCookieName        "a"      stnull) `shouldBe` "a"
      authKey           (setAuthKey           "a"      stnull) `shouldBe` "a"
      idleTimeout       (setIdleTimeout       (Just 1) stnull) `shouldBe` Just 1
      absoluteTimeout   (setAbsoluteTimeout   (Just 1) stnull) `shouldBe` Just 1
      persistentCookies (setPersistentCookies False    stnull) `shouldBe` False
      httpOnlyCookies   (setHttpOnlyCookies   False    stnull) `shouldBe` False
      secureCookies     (setSecureCookies     True     stnull) `shouldBe` True

  describe "loadSession" $ do
    let checkEmptySession (sessionMap, SaveSessionToken msession time) = do
          -- Saved time is close to now, session map is empty,
          -- there's no reference to an existing session.
          let point1 = 0.1 {- second -} :: Double
          now <- TI.getCurrentTime
          abs (realToFrac $ TI.diffUTCTime now time) `shouldSatisfy` (< point1)
          sessionMap `shouldBe` TNTSessionData
          msession `shouldSatisfy` isNothing

    it "returns empty session and token when the session ID cookie is not present" $ do
      ret <- loadSession sttnt Nothing
      checkEmptySession ret

    it "does not need the storage if session ID cookie has invalid data" $ do
      ret <- loadSession sttnt (Just "123456789-123456789-123")
      checkEmptySession ret

    it "returns empty session and token when the session ID cookie refers to inexistent session" $ do
      -- In particular, the save token should *not* refer to the
      -- session ID that was given.  We're a strict session
      -- management system.
      -- <https://www.owasp.org/index.php/Session_Management_Cheat_Sheet#Session_ID_Generation_and_Verification:_Permissive_and_Strict_Session_Management>
      st  <- createState =<< emptyMockStorage
      ret <- loadSession st (Just "123456789-123456789-1234")
      checkEmptySession ret

    it "returns the session from the storage when the session ID refers to an existing session" $ do
      now <- TI.getCurrentTime
      let session = Session
            { sessionKey        = S "123456789-123456789-1234"
            , sessionAuthId     = Just authId
            , sessionData       = mkSessionMap [("a", "b"), ("c", "d")]
            , sessionCreatedAt  = TI.addUTCTime (-10) now
            , sessionAccessedAt = TI.addUTCTime (-5)  now
            }
          authId = "auth-id"
      st  <- createState =<< prepareMockStorage [session]
      let key = B8.pack $ T.unpack $ unS $ sessionKey session
      (retSessionMap, SaveSessionToken msession _now) <- loadSession st (Just key)
      retSessionMap `shouldBe` onSM (HM.insert (authKey st) authId) (sessionData session)
      msession      `shouldBe` Just session

  describe "checkExpired" $ do
    prop "agrees with nextExpires" $
      \idleSecs absSecs ->
        let idleDiff  = realToFrac $ max 1 $ abs (idleSecs :: Int)
            absDiff   = realToFrac $ max 1 $ abs (absSecs  :: Int)
            st'       = setIdleTimeout     (Just idleDiff) $
                        setAbsoluteTimeout (Just absDiff) stnull
            sessTimes = do
              diff <- [0, idleDiff, absDiff]
              off <- [1, 0, -1]
              return $ TI.addUTCTime (negate $ diff + off) fakenow
            sessions  = do
              createdAt  <- sessTimes
              accessedAt <- sessTimes
              return $ Session
                { sessionKey        = error "irrelevant 1"
                , sessionAuthId     = error "irrelevant 2"
                , sessionData       = error "irrelevant 3"
                , sessionCreatedAt  = createdAt
                , sessionAccessedAt = accessedAt
                }
            test s =
              Q.counterexample
                (unlines
                   [ "fakenow    = " ++ show fakenow
                   , "createdAt  = " ++ show (sessionCreatedAt s)
                   , "accessedAt = " ++ show (sessionAccessedAt s)
                   , "checkRet   ~ " ++ show (() <$ checkRet)
                   , "nextRet    = " ++ show nextRet ])
                (isJust checkRet == (nextRet >= Just fakenow))
              where checkRet = checkExpired fakenow st' s
                    nextRet  = nextExpires st' s
        in Q.conjoin (test <$> sessions)

  describe "nextExpires" $ do
    it "looks sane" $ do
      let st i a = setIdleTimeout (f i) $ setAbsoluteTimeout (f a) $ stnull
            where f = fmap (realToFrac :: Int -> TI.NominalDiffTime)
          session a c = Session
            { sessionKey        = irr 1
            , sessionAuthId     = irr 2
            , sessionData       = irr 3
            , sessionCreatedAt  = c
            , sessionAccessedAt = a
            }
          add x = TI.addUTCTime x fakenow
          irr :: Int -> a
          irr = error . ("irrelevant " ++) . show
      nextExpires (st Nothing  Nothing)  (session (irr 4) (irr 5)) `shouldBe` Nothing
      nextExpires (st (Just 1) Nothing)  (session fakenow (irr 6)) `shouldBe` Just (add 1)
      nextExpires (st Nothing  (Just 1)) (session (irr 7) fakenow) `shouldBe` Just (add 1)
      nextExpires (st (Just 3) (Just 7)) (session fakenow fakenow) `shouldBe` Just (add 3)
      nextExpires (st (Just 3) (Just 7)) (session (add 4) fakenow) `shouldBe` Just (add 7)
      nextExpires (st (Just 3) (Just 7)) (session (add 5) fakenow) `shouldBe` Just (add 7)

  describe "cookieExpires" $ do
    prop "is Nothing for non-persistent cookies regardless of session" $
      \midleSecs mabsSecs ->
        let idleDiff  = realToFrac . max 1 . abs <$> (midleSecs :: Maybe Int)
            absDiff   = realToFrac . max 1 . abs <$> (mabsSecs  :: Maybe Int)
            st'       = setIdleTimeout       idleDiff $
                        setAbsoluteTimeout   absDiff  $
                        setPersistentCookies False stnull
        in cookieExpires st' (error "irrelevant") Q.=== Nothing
    it "is a long time for persistent cookies without timeouts regardless of session" $
      let st' = setIdleTimeout     Nothing $
                setAbsoluteTimeout Nothing stnull
          session = Session
            { sessionKey        = error "irrelevant 1"
            , sessionAuthId     = error "irrelevant 2"
            , sessionData       = error "irrelevant 3"
            , sessionCreatedAt  = error "irrelevant 4"
            , sessionAccessedAt = fakenow
            }
          distantFuture = TI.addUTCTime (60*60*24*365*10) fakenow
      in cookieExpires st' session `shouldSatisfy` maybe False (>= distantFuture)

  describe "saveSession" $ do
    -- We already test the other functions that saveSession
    -- calls.  A single unit test just to be sure everything is
    -- connected should be enough.
    it "works for a complex example" $ do
      sto <- emptyMockStorage
      st  <- createState sto
      saveSession st (SaveSessionToken Nothing fakenow) emptySM `shouldReturn` Nothing
      getMockOperations sto `shouldReturn` []

      let m1 = mkSessionMap [("a", "b")]
      Just session1 <- saveSession st (SaveSessionToken Nothing fakenow) m1
      sessionAuthId session1 `shouldBe` Nothing
      sessionData   session1 `shouldBe` m1
      getMockOperations sto `shouldReturn` [InsertSession session1]

      let m2 = onSM (HM.insert (authKey st) "john") m1
      Just session2 <- saveSession st (SaveSessionToken (Just session1) fakenow) m2
      sessionAuthId session2 `shouldBe` Just "john"
      sessionData   session2 `shouldBe` m1
      sessionKey session2 == sessionKey session1 `shouldBe` False
      getMockOperations sto `shouldReturn` [DeleteSession (sessionKey session1), InsertSession session2]

      let m3 = onSM (HM.insert forceInvalidateKey (B8.pack $ show AllSessionIdsOfLoggedUser)) m2
      Just session3 <- saveSession st (SaveSessionToken (Just session2) fakenow) m3
      session3 `shouldBe` session2 { sessionKey = sessionKey session3 }
      getMockOperations sto `shouldReturn`
        [DeleteSession (sessionKey session2), DeleteAllSessionsOfAuthId "john", InsertSession session3]

      let m4 = onSM (HM.insert "x" "y") m2
      Just session4 <- saveSession st (SaveSessionToken (Just session3) fakenow) m4
      session4 `shouldBe` session3 { sessionData = onSM (HM.delete (authKey st)) m4 }
      getMockOperations sto `shouldReturn` [ReplaceSession session4]

      Just session5 <- saveSession st (SaveSessionToken (Just session4) (TI.addUTCTime 10 fakenow)) m4
      session5 `shouldBe` session4
      getMockOperations sto `shouldReturn` []

  describe "invalidateIfNeeded" $ do
    let prepareInvalidateIfNeeded authId = do
          let oldSession = Session
                { sessionKey        = S "123456789-123456789-1234"
                , sessionAuthId     = authId
                , sessionData       = emptySM
                , sessionCreatedAt  = TI.addUTCTime (-10) fakenow
                , sessionAccessedAt = TI.addUTCTime (-5)  fakenow }
          sto <- prepareMockStorage [oldSession]
          st  <- createState sto
          return (oldSession, sto :: MockStorage SessionMap, st)
        allEdges = let x = [Nothing, Just "john", Just "jane"] in (,) <$> x <*> x

    it "does not invalidate when not changing auth ID nor explicitly requesting" $ do
      forM_ [Nothing, Just "john"] $ \authId -> do
        (session, sto, st) <- prepareInvalidateIfNeeded authId
        let d = DecomposedSession authId DoNotForceInvalidate emptySM
        invalidateIfNeeded st (Just session) d `shouldReturn` Just session
        getMockOperations sto `shouldReturn` []

    it "invalidates the current session when changing auth ID" $ do
      forM_ [ (Just "john",  Just "jane")
            , (Just "admin", Nothing)
            , (Nothing,      Just "joe") ] $ \edgeTransition -> do
        (session, sto, st) <- prepareInvalidateIfNeeded (fst edgeTransition)
        let d = DecomposedSession (snd edgeTransition) DoNotForceInvalidate emptySM
        invalidateIfNeeded st (Just session) d `shouldReturn` Nothing
        getMockOperations sto `shouldReturn` [DeleteSession (sessionKey session)]

    it "invalidates the current session when CurrentSessionId is forced" $ do
      forM_ allEdges $ \edgeTransition -> do
        (session, sto, st) <- prepareInvalidateIfNeeded (fst edgeTransition)
        let d = DecomposedSession (snd edgeTransition) CurrentSessionId emptySM
        invalidateIfNeeded st (Just session) d `shouldReturn` Nothing
        getMockOperations sto `shouldReturn` [DeleteSession (sessionKey session)]

    it "invalidates all of the user's sessions when AllSessionIdsOfLoggedUser is forced" $ do
      forM_ allEdges $ \edgeTransition -> do
        (session, sto, st) <- prepareInvalidateIfNeeded (fst edgeTransition)
        let d = DecomposedSession (snd edgeTransition) AllSessionIdsOfLoggedUser emptySM
        invalidateIfNeeded st (Just session) d `shouldReturn` Nothing
        let expected = DeleteSession (sessionKey session) :
                       maybe [] ((:[]) . DeleteAllSessionsOfAuthId) (snd edgeTransition)
                       -- It deletes all sessions only when there's an authId.
        getMockOperations sto `shouldReturn` expected

  describe "saveSessionOnDb" $ do
    let prepareSaveSessionOnDb = do
          let oldSession = Session
                { sessionKey        = S "123456789-123456789-1234"
                , sessionAuthId     = Just "auth"
                , sessionData       = mkSessionMap [("a", "b"), ("c", "d")]
                , sessionCreatedAt  = TI.addUTCTime (-10) fakenow
                , sessionAccessedAt = TI.addUTCTime (-5)  fakenow }
          sto <- prepareMockStorage [oldSession]
          st  <- createState sto
          return (oldSession, sto :: MockStorage SessionMap, st)
        emptyDecomp = DecomposedSession Nothing DoNotForceInvalidate emptySM

    it "inserts new sessions when there wasn't an old one" $ do
      sto <- emptyMockStorage
      st  <- createState (sto :: MockStorage SessionMap)
      let d = DecomposedSession a DoNotForceInvalidate m
          m = mkSessionMap [("a", "b"), ("c", "d")]
          a = Just "auth"
      Just session <- saveSessionOnDb st fakenow Nothing d
      getMockOperations sto `shouldReturn` [InsertSession session]
      sessionAuthId     session `shouldBe` a
      sessionData       session `shouldBe` m
      sessionCreatedAt  session `shouldBe` fakenow
      sessionAccessedAt session `shouldBe` fakenow

    it "replaces sesssions when there was an old one" $ do
      (oldSession, sto, st) <- prepareSaveSessionOnDb
      let d = DecomposedSession Nothing DoNotForceInvalidate m
          m = mkSessionMap [("a", "b"), ("x", "y")]
      Just session <- saveSessionOnDb st fakenow (Just oldSession) d
      getMockOperations sto `shouldReturn` [ReplaceSession session]
      session `shouldBe` oldSession
                           { sessionData       = m
                           , sessionAuthId     = Nothing
                           , sessionAccessedAt = fakenow }

    it "does not save session if it's empty and there wasn't an old one" $ do
      sto <- emptyMockStorage
      st  <- createState sto
      saveSessionOnDb st fakenow Nothing emptyDecomp `shouldReturn` Nothing
      getMockOperations sto `shouldReturn` []

    it "saves session if it's empty but there was an old one" $ do
      (oldSession, sto, st) <- prepareSaveSessionOnDb
      let newSession = oldSession { sessionData       = emptySM
                                  , sessionAuthId     = Nothing
                                  , sessionAccessedAt = fakenow }
      saveSessionOnDb st fakenow (Just oldSession) emptyDecomp `shouldReturn` Just newSession
      getMockOperations sto `shouldReturn` [ReplaceSession newSession]

    it "respects the timeout resolution" $ do
      (session1, sto, st) <- prepareSaveSessionOnDb
      let d = DecomposedSession (sessionAuthId session1) DoNotForceInvalidate (sessionData session1)
      saveSessionOnDb st fakenow (Just session1) d `shouldReturn` Just session1
      getMockOperations sto `shouldReturn` []
      let t i = TI.addUTCTime (res + i) (sessionAccessedAt session1)
          Just res = timeoutResolution st
      saveSessionOnDb st (t (-1)) (Just session1) d `shouldReturn` Just session1
      getMockOperations sto `shouldReturn` []
      -- We don't care about t 0, timeoutResolution is Maybe anyway.
      let session2 = session1 { sessionAccessedAt = t 1 }
      saveSessionOnDb st (t 1) (Just session1) d `shouldReturn` Just session2
      getMockOperations sto `shouldReturn` [ReplaceSession session2]

  describe "decomposeSession/SessionMap" $ do
    let authKey_ = authKey stnull

    prop "it is sane when not finding auth key or force invalidate key" $
      \data_ ->
        let sessionMap = mkSessionMap $ filter (notSpecial . fst) $ data_
            notSpecial = flip notElem [authKey stnull, forceInvalidateKey] . T.pack
        in decomposeSession authKey_ sessionMap `shouldBe`
           DecomposedSession Nothing DoNotForceInvalidate sessionMap

    prop "parses the force invalidate key" $
      \data_  ->
        let sessionMap v = onSM (HM.insert forceInvalidateKey (B8.pack $ show v)) $ mkSessionMap data_
            allForces    = [minBound..maxBound] :: [ForceInvalidate]
            test v       = dsForceInvalidate (decomposeSession authKey_ $ sessionMap v) Q.=== v
        in Q.conjoin (test <$> allForces)

    it "removes the auth key" $ do
      let m = HM.singleton "a" "b"; m' = HM.insert (authKey stnull) "x" m
      decomposeSession authKey_ (SessionMap m') `shouldBe`
        DecomposedSession (Just "x") DoNotForceInvalidate (SessionMap m)

  describe "recomposeSession/SessionMap" $ do
    let authKey_ = authKey stnull

    prop "does not change session data for sessions without auth ID" $
      \data_ ->
        let s = mkSessionMap data_
        in recomposeSession authKey_ Nothing s Q.=== s

    prop "adds (overwriting) the auth ID to the session data" $
      \authId_ data_ ->
        let s = mkSessionMap ((T.unpack authKey_, "foo") : data_)
            authId = B8.pack authId_
        in       recomposeSession authKey_ (Just authId) s
           Q.=== onSM (HM.adjust (const authId) authKey_) s

  describe "MockStorage" $ do
    sto <- runIO emptyMockStorage
    allStorageTests sto it runIO parallel shouldBe shouldReturn shouldThrow


-- | Used to generate session maps on QuickCheck properties.
mkSessionMap :: [(String, String)] -> SessionMap
mkSessionMap = SessionMap . HM.fromList . map (T.pack *** B8.pack)


-- | Apply a function to a 'SessionMap'.
onSM
  :: (HM.HashMap T.Text B8.ByteString -> HM.HashMap T.Text B8.ByteString)
  -> (SessionMap                      -> SessionMap)
onSM f = SessionMap . f . unSessionMap


-- | Empty 'SessionMap'.
emptySM :: SessionMap
emptySM = emptySession


----------------------------------------------------------------------


-- | A storage that explodes if it's used.  Useful for checking
-- that the storage is irrelevant on a code path.
data TNTStorage = TNTStorage deriving (Typeable)

instance Storage TNTStorage where
  type TransactionM TNTStorage = IO
  type SessionData TNTStorage = TNTSessionData
  runTransactionM _         = id
  getSession                = explode "getSession"
  deleteSession             = explode "deleteSession"
  deleteAllSessionsOfAuthId = explode "deleteAllSessionsOfAuthId"
  insertSession             = explode "insertSession"
  replaceSession            = explode "replaceSession"


-- | Implementation of all 'Storage' methods of 'TNTStorage'
-- (except for runTransactionM).
explode :: Show a => String -> TNTStorage -> a -> TransactionM TNTStorage b
explode fun _ = E.throwIO . TNTExplosion fun . show


-- | Exception thrown by 'explode'.
data TNTExplosion = TNTExplosion String String deriving (Show, Typeable)

instance E.Exception TNTExplosion where


-- | Session data that explodes if it's used.  Doesn't explode on
-- 'emptySession'.
data TNTSessionData = TNTSessionData deriving (Eq, Show, Typeable)

instance IsSessionData TNTSessionData where
  type Decomposed TNTSessionData = ()
  emptySession = TNTSessionData
  isSameDecomposed _ = curry (explodeD "isSameDecomposed")
  decomposeSession = curry (explodeD "decomposeSession")
  recomposeSession = (curry . curry) (explodeD "recomposeSession")
  isDecomposedEmpty _ = explodeD "isDecomposedEmpty"


-- | Implementation of all 'IsSessionData' methods of
-- 'TNTSessionData'.
explodeD :: Show a => String -> a -> b
explodeD fun = E.throw . TNTExplosion fun . show


----------------------------------------------------------------------


-- | A mock operation that was executed.
data MockOperation sess =
    GetSession (SessionId sess)
  | DeleteSession (SessionId sess)
  | DeleteAllSessionsOfAuthId AuthId
  | InsertSession (Session sess)
  | ReplaceSession (Session sess)
    deriving (Typeable)

deriving instance Eq   (Decomposed sess) => Eq   (MockOperation sess)
deriving instance Show (Decomposed sess) => Show (MockOperation sess)


-- | A mock storage used just for testing.
data MockStorage sess =
  MockStorage
    { mockSessions   :: I.IORef (HM.HashMap (SessionId sess) (Session sess))
    , mockOperations :: I.IORef [MockOperation sess]
    }
  deriving (Typeable)

instance IsSessionData sess => Storage (MockStorage sess) where
  type TransactionM (MockStorage sess) = IO
  type SessionData (MockStorage sess) = sess
  runTransactionM _ = id
  getSession sto sid = do
    -- We need to use atomicModifyIORef instead of readIORef
    -- because latter may be reordered (cf. "Memory Model" on
    -- Data.IORef's documentation).
    addMockOperation sto (GetSession sid)
    HM.lookup sid <$> I.atomicModifyIORef' (mockSessions sto) (\a -> (a, a))
  deleteSession sto sid = do
    I.atomicModifyIORef' (mockSessions sto) ((, ()) . HM.delete sid)
    addMockOperation sto (DeleteSession sid)
  deleteAllSessionsOfAuthId sto authId = do
    I.atomicModifyIORef' (mockSessions sto) ((, ()) . HM.filter (\s -> sessionAuthId s /= Just authId))
    addMockOperation sto (DeleteAllSessionsOfAuthId authId)
  insertSession sto session = do
    join $ I.atomicModifyIORef' (mockSessions sto) $ \oldMap ->
      case HM.lookup (sessionKey session) oldMap of
        Just oldVal -> (oldMap, mockThrow $ SessionAlreadyExists oldVal session)
        Nothing     -> (HM.insert (sessionKey session) session oldMap, return ())
    addMockOperation sto (InsertSession session)
  replaceSession sto session = do
    join $ I.atomicModifyIORef' (mockSessions sto) $ \oldMap ->
      case HM.lookup (sessionKey session) oldMap of
        Just _  -> (HM.insert (sessionKey session) session oldMap, return ())
        Nothing -> (oldMap, mockThrow $ SessionDoesNotExist session)
    addMockOperation sto (ReplaceSession session)


-- | Specialization of 'E.throwIO' for 'MockStorage'.
mockThrow
  :: IsSessionData sess
  => StorageException (MockStorage sess)
  -> TransactionM (MockStorage sess) a
mockThrow = E.throwIO


-- | Creates empty mock storage.
emptyMockStorage :: IO (MockStorage sess)
emptyMockStorage =
  MockStorage
    <$> I.newIORef HM.empty
    <*> I.newIORef []


-- | Creates mock storage with the given sessions already existing.
prepareMockStorage :: [Session sess] -> IO (MockStorage sess)
prepareMockStorage sessions = do
  sto <- emptyMockStorage
  I.writeIORef (mockSessions sto) (HM.fromList [(sessionKey s, s) | s <- sessions])
  return sto


-- | Get the list of mock operations that were made and clear
-- them.  The operations are listed in chronological order.
getMockOperations :: MockStorage sess -> IO [MockOperation sess]
getMockOperations = flip I.atomicModifyIORef' ((,) [] . reverse) . mockOperations


-- | Add a mock operations to the log.
addMockOperation :: MockStorage sess -> MockOperation sess -> IO ()
addMockOperation sto op = I.atomicModifyIORef' (mockOperations sto) $ \ops -> (op:ops, ())
