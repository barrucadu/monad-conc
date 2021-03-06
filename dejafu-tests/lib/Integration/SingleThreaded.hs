{-# LANGUAGE FlexibleContexts #-}

module Integration.SingleThreaded where

import           Control.Exception         (ArithException(..),
                                            ArrayException(..),
                                            MaskingState(..))
import           Test.DejaFu               (Condition(..), gives, gives',
                                            inspectIORef, inspectMVar,
                                            inspectTVar, isDeadlock,
                                            isInvariantFailure,
                                            isUncaughtException,
                                            registerInvariant, withSetup)

import           Control.Concurrent.Classy
import           Control.Monad             (replicateM_, when)
import           Control.Monad.Catch       (throwM)
import           Control.Monad.Fail        (MonadFail)
import           Control.Monad.IO.Class    (liftIO)
import qualified Data.IORef                as IORef
import           Data.Maybe                (isNothing)
import           System.Random             (mkStdGen)

import           Common

tests :: [TestTree]
tests =
  [ testGroup "MVar" mvarTests
  , testGroup "IORef" iorefTests
  , testGroup "STM" stmTests
  , testGroup "Exceptions" exceptionTests
  , testGroup "Capabilities" capabilityTests
  , testGroup "Program" programTests
  , testGroup "IO" ioTests
  ]

--------------------------------------------------------------------------------

mvarTests :: [TestTree]
mvarTests = toTestList
  [ djfu "Taking from an empty MVar blocks" (gives [Left Deadlock]) $ do
      var <- newEmptyMVarInt
      takeMVar var

  , djfu "Non-blockingly taking from an empty MVar gives nothing" (gives' [Nothing]) $ do
      var <- newEmptyMVarInt
      tryTakeMVar var

  , djfu "Putting into an empty MVar updates it" (gives' [True]) $ do
      var <- newEmptyMVarInt
      putMVar var 7
      (==7) <$> readMVar var

  , djfu "Non-blockingly putting into an empty MVar updates it" (gives' [True]) $ do
      var <- newEmptyMVarInt
      _   <- tryPutMVar var 7
      (==7) <$> readMVar var

  , djfu "Reading an empty MVar blocks" (gives [Left Deadlock]) $ do
      var <- newEmptyMVarInt
      readMVar var

  , djfu "Non-blockingly reading an empty MVar gives nothing" (gives' [Nothing]) $ do
      var <- newEmptyMVarInt
      tryReadMVar var

  , djfu "Putting into a full MVar blocks" (gives [Left Deadlock]) $ do
      var <- newMVarInt 7
      putMVar var 10

  , djfu "Non-blockingly putting into a full MVar fails" (gives' [False]) $ do
      var <- newMVarInt 7
      tryPutMVar var 10

  , djfu "Taking from a full MVar works" (gives' [True]) $ do
      var <- newMVarInt 7
      (==7) <$> takeMVar var

  , djfu "Non-blockingly taking from a full MVar works" (gives' [True]) $ do
      var <- newMVarInt 7
      (==Just 7) <$> tryTakeMVar var

  , djfu "Reading a full MVar works" (gives' [True]) $ do
      var <- newMVarInt 7
      (==7) <$> readMVar var

  , djfu "Non-blockingly reading a full MVar works" (gives' [True]) $ do
      var <- newMVarInt 7
      (==Just 7) <$> tryReadMVar var
  ]

--------------------------------------------------------------------------------

iorefTests :: [TestTree]
iorefTests = toTestList
  [ djfu "Reading a non-updated IORef gives its initial value" (gives' [True]) $ do
      ref <- newIORefInt 5
      (5==) <$> readIORef ref

  , djfu "Reading an updated IORef gives its new value" (gives' [True]) $ do
      ref <- newIORefInt 5
      writeIORef ref 6
      (6==) <$> readIORef ref

  , djfu "Updating a IORef by a function changes its value" (gives' [True]) $ do
      ref <- newIORefInt 5
      atomicModifyIORef ref (\i -> (i+1, ()))
      (6==) <$> readIORef ref

  , djfu "A ticket contains the value of the IORef at the time of its creation" (gives' [True]) $ do
      ref  <- newIORefInt 5
      tick <- readForCAS ref
      writeIORef ref 6
      (5==) <$> peekTicket tick

  , djfu "Compare-and-swap returns a ticket containing the new value" (gives' [True]) $ do
      ref  <- newIORefInt 5
      tick <- readForCAS ref
      (_, tick') <- casIORef ref tick 6
      (6==) <$> peekTicket tick'

  , djfu "Compare-and-swap on an unmodified IORef succeeds" (gives' [True]) $ do
      ref  <- newIORefInt 5
      tick <- readForCAS ref
      (suc, _) <- casIORef ref tick 6
      val <- readIORef ref
      pure (suc && (6 == val))

  , djfu "Compare-and-swap on a modified IORef fails" (gives' [True]) $ do
      ref  <- newIORefInt 5
      tick <- readForCAS ref
      writeIORef ref 6
      (suc, _) <- casIORef ref tick 7
      val <- readIORef ref
      pure (not suc && 7 /= val)
  ]

--------------------------------------------------------------------------------

stmTests :: [TestTree]
stmTests = toTestList
  [ djfu "When a TVar is updated, its new value is visible later in same transaction" (gives' [True]) $
      (6==) <$> atomically (do { v <- newTVarInt 5; writeTVar v 6; readTVar v })

  , djfu "When a TVar is updated, its new value is visible in a later transaction" (gives' [True]) $ do
      ctv <- atomically $ newTVarInt 5
      (5==) <$> readTVarConc ctv

  , djfu "Aborting a transaction blocks the thread" (gives [Left Deadlock])
      (atomically retry :: MonadConc m => m ()) -- avoid an ambiguous type

  , djfu "Aborting a transaction can be caught and recovered from" (gives' [True]) $ do
      ctv <- atomically $ newTVarInt 5
      atomically $ orElse retry (writeTVar ctv 6)
      (6==) <$> readTVarConc ctv

  , djfu "An exception thrown in a transaction can be caught" (gives' [True]) $ do
      ctv <- atomically $ newTVarInt 5
      atomically $ catchArithException
        (throwSTM Overflow)
        (\_ -> writeTVar ctv 6)
      (6==) <$> readTVarConc ctv

  , djfu "Nested exception handlers in transactions work" (gives' [True]) $ do
      ctv <- atomically $ newTVarInt 5
      atomically $ catchArithException
        (catchArrayException
          (throwSTM Overflow)
          (\_ -> writeTVar ctv 0))
        (\_ -> writeTVar ctv 6)
      (6==) <$> readTVarConc ctv

  , djfu "MonadSTM is a MonadFail" (alwaysFailsWith isUncaughtException)
      (atomically $ fail "hello world" :: (MonadConc m, MonadFail (STM m)) => m ())  -- avoid an ambiguous type

  , djfu "'retry' is not caught by 'catch'" (gives' [True]) $
      atomically
        ((retry `catchSomeException` \_ -> pure False) `orElse` pure True)

  , djfu "'throw' is not caught by 'orElse'" (gives' [True]) $
      atomically
        ((throwSTM Overflow `orElse` pure False) `catchSomeException` \_ -> pure True)

  , djfu "'retry' in a nested 'orElse' only aborts the innermost" (gives' [True]) $
      atomically
       ((retry `orElse` pure True) `orElse` pure False)
  ]

--------------------------------------------------------------------------------

exceptionTests :: [TestTree]
exceptionTests = toTestList
  [ djfu "An exception thrown can be caught" (gives' [True]) $
      catchArithException
        (throw Overflow)
        (\_ -> pure True)

  , djfu "Nested exception handlers work" (gives' [True]) $
      catchArithException
        (catchArrayException
          (throw Overflow)
          (\_ -> pure False))
        (\_ -> pure True)

  , djfu "Uncaught exceptions kill the computation" (alwaysFailsWith isUncaughtException) $
      catchArithException
        (throw $ IndexOutOfBounds "")
        (\_ -> pure False)

  , djfu "SomeException matches all exception types" (gives' [True]) $ do
      a <- catchSomeException
           (throw Overflow)
           (\_ -> pure True)
      b <- catchSomeException
           (throw $ IndexOutOfBounds "")
           (\_ -> pure True)
      pure (a && b)

  , djfu "Exceptions thrown in a transaction can be caught outside it" (gives' [True]) $
      catchArithException
        (atomically $ throwSTM Overflow)
        (\_ -> pure True)

  , djfu "Throwing an unhandled exception to the main thread kills it" (alwaysFailsWith isUncaughtException) $ do
      tid <- myThreadId
      throwTo tid Overflow

  , djfu "Throwing a handled exception to the main thread does not kill it" (gives' [True]) $ do
      tid <- myThreadId
      catchArithException (throwTo tid Overflow >> pure False) (\_ -> pure True)

  , djfu "MonadConc is a MonadFail" (alwaysFailsWith isUncaughtException)
      (fail "hello world" :: (MonadConc m, MonadFail m) => m ())  -- avoid an ambiguous type

  , djfu "Masking state is changed by a mask" (gives' [MaskedInterruptible]) $
      mask_ getMaskingState

  , djfu "Masking state is reset after the mask ends" (gives' [Unmasked]) $
      mask_ getMaskingState >> getMaskingState
  ]

--------------------------------------------------------------------------------

capabilityTests :: [TestTree]
capabilityTests = toTestList
  [ djfu "Reading the capabilities twice without update gives the same result" (gives' [True]) $ do
      c1 <- getNumCapabilities
      c2 <- getNumCapabilities
      pure (c1 == c2)

  , djfu "Getting the updated capabilities gives the new value" (gives' [True]) $ do
      caps <- getNumCapabilities
      setNumCapabilities (caps + 1)
      (== caps + 1) <$> getNumCapabilities
  ]

--------------------------------------------------------------------------------

programTests :: [TestTree]
programTests = toTestList
  [ testGroup "withSetup"
    [ djfu "Inner state modifications are visible to the outside" (gives' [True]) $
        withSetup
          (do inner <- newEmptyMVarInt
              putMVar inner 5
              pure inner)
          (fmap (==5) . takeMVar)

    , djfu "Failures abort the whole computation" (alwaysFailsWith isDeadlock) $
        withSetup (takeMVar =<< newEmptyMVarInt) (\_ -> pure True)

    -- we use 'randomly' here because we specifically want to compare
    -- multiple executions with snapshotting
    , toTestList . testGroup "Snapshotting" $ let snapshotTest n p conc = W n conc p ("randomly", randomly (mkStdGen 0) 150) in
      [ snapshotTest "State updates are applied correctly" (gives' [2]) $
          withSetup
            (do r <- newIORefInt 0
                writeIORef r 1
                writeIORef r 2
                pure r)
            readIORef

      , snapshotTest "Lifted IO is re-run (1)" (gives' [2..151]) $
          withSetup
            (do r <- liftIO (IORef.newIORef (0::Int))
                liftIO (IORef.modifyIORef r (+1))
                pure r)
            (liftIO . IORef.readIORef)

      , snapshotTest "Lifted IO is re-run (2)" (gives' [1]) $
          withSetup
            (do let modify r f = liftIO (IORef.readIORef r) >>= liftIO . IORef.writeIORef r . f
                r <- liftIO (IORef.newIORef (0::Int))
                modify r (+1)
                pure r)
            (liftIO . IORef.readIORef)

      , snapshotTest "Lifted IO is re-run (3)" (gives' [1]) $
          withSetup
            (do r <- liftIO (IORef.newIORef (0::Int))
                liftIO (IORef.writeIORef r 0)
                liftIO (IORef.modifyIORef r (+1))
                pure r)
          (liftIO . IORef.readIORef)
      ]
    ]

  , testGroup "withSetupAndTeardown"
    [ djfuS "Failures can be observed" (gives' [True]) $
        withSetupAndTeardown
          (pure ())
          (\_ -> pure . either (== Deadlock) (const False))
          (\_ -> newEmptyMVar >>= readMVar)

    , djfuS "Teardown always happens" (gives' [True]) $
        withSetupAndTeardown
          (newMVarInt 0)
          (\var x -> do
              y <- readMVar var
              pure (either (==Deadlock) (const False) x && y == 0))
          (\var -> putMVar var 1)

    , djfuS "Non-failing inner action returns the final result" (gives' [True]) $
        withSetupAndTeardown
          (newMVarInt 3)
          (\_ x -> pure (either (const False) (==3) x))
          takeMVar
    ]

  , testGroup "registerInvariant"
    [ djfuS "An uncaught exception fails an invariant" (alwaysFailsWith isInvariantFailure) $
        withSetup (registerInvariant (throwM Overflow)) $
          \() -> pure True
    , djfuS "An invariant which never throws always passes" (gives' [True]) $
        withSetup (registerInvariant (pure ())) $
          \() -> pure True
    , djfuS "An invariant can catch exceptions" (gives' [True]) $
        withSetup (registerInvariant (throwM Overflow `catchArithException` \_ -> pure ())) $
          \() -> pure True
    , djfuS "Invariants can read MVars" (alwaysFailsWith isInvariantFailure) $
        withSetup
          (do v <- newMVarInt 10
              registerInvariant (inspectMVar v >>= \x -> when (isNothing x) (throwM Overflow))
              pure v)
          takeMVar
    , djfuS "Invariants can read TVars" (alwaysFailsWith isInvariantFailure) $
        withSetup
          (do v <- atomically (newTVar (10::Int))
              registerInvariant (inspectTVar v >>= \x -> when (x < 5) (throwM Overflow))
              pure v)
          (\v -> atomically (writeTVar v 1))
    , djfuS "Invariants aren't checked in the setup" (gives' [True]) $
        withSetup
          (do v <- newIORefInt 10
              registerInvariant (inspectIORef v >>= \x -> when (x < 5) (throwM Overflow))
              writeIORef v 1
              writeIORef v 10)
          (\_ -> pure True)
    , djfuS "Invariants aren't checked in the teardown" (gives' [True]) $
        withSetupAndTeardown
          (do v <- newIORefInt 10
              registerInvariant (inspectIORef v >>= \x -> when (x < 5) (throwM Overflow))
              pure v)
          (\v _ -> do
              writeIORef v 1
              writeIORef v 10
              pure True)
          (\_ -> pure ())
    , djfuS "Invariants aren't checked if added in the main phase" (gives' [True]) $ do
        v <- newIORefInt 10
        registerInvariant (inspectIORef v >>= \x -> when (x < 5) (throwM Overflow))
        writeIORef v 1
        pure True
    ]
  ]

-------------------------------------------------------------------------------

ioTests :: [TestTree]
ioTests = toTestList
  [ djfu "Lifted IO is performed" (gives' [3]) $ do
      r <- liftIO (IORef.newIORef (0::Int))
      replicateM_ 3 (liftIO (IORef.atomicModifyIORef r (\i -> (i+1, ()))))
      liftIO (IORef.readIORef r)
  ]
