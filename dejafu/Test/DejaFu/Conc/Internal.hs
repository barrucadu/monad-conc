{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Test.DejaFu.Conc.Internal
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : RankNTypes, ScopedTypeVariables
--
-- Concurrent monads with a fixed scheduler: internal types and
-- functions. This module is NOT considered to form part of the public
-- interface of this library.
module Test.DejaFu.Conc.Internal where

import Control.Exception (MaskingState(..), toException)
import Control.Monad.Ref (MonadRef, newRef, readRef, writeRef)
import Data.Functor (void)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty(..), fromList)
import qualified Data.Map.Strict as M
import Data.Maybe (fromJust, fromMaybe, isJust, isNothing, listToMaybe)

import Test.DejaFu.Common
import Test.DejaFu.Conc.Internal.Common
import Test.DejaFu.Conc.Internal.Memory
import Test.DejaFu.Conc.Internal.Threading
import Test.DejaFu.Schedule
import Test.DejaFu.STM (Result(..))

{-# ANN module ("HLint: ignore Use record patterns" :: String) #-}
{-# ANN module ("HLint: ignore Use const"           :: String) #-}

--------------------------------------------------------------------------------
-- * Execution

-- | Run a concurrent computation with a given 'Scheduler' and initial
-- state, returning a failure reason on error. Also returned is the
-- final state of the scheduler, and an execution trace (in reverse
-- order).
runConcurrency :: MonadRef r n
               => (forall x. s x -> IdSource -> n (Result x, IdSource, TTrace))
               -> Scheduler g
               -> MemType
               -> g
               -> M n r s a
               -> n (Either Failure a, g, Trace)
runConcurrency runstm sched memtype g ma = do
  ref <- newRef Nothing

  let c = runCont ma (AStop . writeRef ref . Just . Right)
  let threads = launch' Unmasked initialThread (const c) M.empty

  (g', trace) <- runThreads runstm
                            sched
                            memtype
                            g
                            threads
                            initialIdSource
                            ref

  out <- readRef ref

  pure (fromJust out, g', trace)

-- | Run a collection of threads, until there are no threads left.
--
-- Note: this returns the trace in reverse order, because it's more
-- efficient to prepend to a list than append. As this function isn't
-- exposed to users of the library, this is just an internal gotcha to
-- watch out for.
runThreads :: MonadRef r n => (forall x. s x -> IdSource -> n (Result x, IdSource, TTrace))
           -> Scheduler g -> MemType -> g -> Threads n r s -> IdSource -> r (Maybe (Either Failure a)) -> n (g, Trace)
runThreads runstm sched memtype origg origthreads idsrc ref = go idsrc [] Nothing origg origthreads emptyBuffer 2 where
  go idSource sofar prior g threads wb caps
    | isTerminated  = stop g
    | isDeadlocked  = die g Deadlock
    | isSTMLocked   = die g STMDeadlock
    | isAborted     = die g' Abort
    | isNonexistant = die g' InternalError
    | isBlocked     = die g' InternalError
    | otherwise = do
      stepped <- stepThread runstm sched memtype g (_continuation $ fromJust thread) idSource chosen threads wb caps
      case stepped of
        Right (threads', idSource', act, wb', caps', mg') -> loop threads' idSource' act (fromMaybe g' mg') wb' caps'

        Left UncaughtException
          | chosen == initialThread -> die g' UncaughtException
          | otherwise -> loop (kill chosen threads) idSource (Right Killed) g' wb caps

        Left failure -> die g' failure

    where
      (choice, g')  = sched (map (\(d,_,a) -> (d,a)) $ reverse sofar) ((\p (_,_,a) -> (p,a)) <$> prior <*> listToMaybe sofar) (fromList $ map (\(t,l:|_) -> (t,l)) runnable') g
      chosen        = fromJust choice
      runnable'     = [(t, nextActions t) | t <- sort $ M.keys runnable]
      runnable      = M.filter (isNothing . _blocking) threadsc
      thread        = M.lookup chosen threadsc
      threadsc      = addCommitThreads wb threads
      isAborted     = isNothing choice
      isBlocked     = isJust . _blocking $ fromJust thread
      isNonexistant = isNothing thread
      isTerminated  = initialThread `notElem` M.keys threads
      isDeadlocked  = M.null (M.filter (isNothing . _blocking) threads) &&
        (((~=  OnMVarFull  undefined) <$> M.lookup initialThread threads) == Just True ||
         ((~=  OnMVarEmpty undefined) <$> M.lookup initialThread threads) == Just True ||
         ((~=  OnMask      undefined) <$> M.lookup initialThread threads) == Just True)
      isSTMLocked = M.null (M.filter (isNothing . _blocking) threads) &&
        ((~=  OnTVar []) <$> M.lookup initialThread threads) == Just True

      unblockWaitingOn tid = fmap unblock where
        unblock thrd = case _blocking thrd of
          Just (OnMask t) | t == tid -> thrd { _blocking = Nothing }
          _ -> thrd

      decision
        | Just chosen == prior = Continue
        | prior `notElem` map (Just . fst) runnable' = Start chosen
        | otherwise = SwitchTo chosen

      nextActions t = lookahead . _continuation . fromJust $ M.lookup t threadsc

      stop outg = pure (outg, sofar)
      die  outg reason = writeRef ref (Just $ Left reason) >> stop outg

      loop threads' idSource' trcOrAct g'' =
        let trc = case trcOrAct of
              Left (act, acts) -> (decision, runnable', act) : acts
              Right act -> [(decision, runnable', act)]
            sofar' =  trc++sofar
            threads'' = if (interruptible <$> M.lookup chosen threads') /= Just False then unblockWaitingOn chosen threads' else threads'
        in go idSource' sofar' (Just chosen) g'' (delCommitThreads threads'')

--------------------------------------------------------------------------------
-- * Single-step execution

-- | Run a single thread one step, by dispatching on the type of
-- 'Action'.
stepThread :: forall n r s g. MonadRef r n
  => (forall x. s x -> IdSource -> n (Result x, IdSource, TTrace))
  -- ^ Run a 'MonadSTM' transaction atomically.
  -> Scheduler g
  -- ^ The scheduler.
  -> MemType
  -- ^ The memory model
  -> g
  -- ^ The scheduler state.
  -> Action n r s
  -- ^ Action to step
  -> IdSource
  -- ^ Source of fresh IDs
  -> ThreadId
  -- ^ ID of the current thread
  -> Threads n r s
  -- ^ Current state of threads
  -> WriteBuffer r
  -- ^ @CRef@ write buffer
  -> Int
  -- ^ The number of capabilities
  -> n (Either Failure (Threads n r s, IdSource, Either (ThreadAction, Trace) ThreadAction, WriteBuffer r, Int, Maybe g))
stepThread runstm sched memtype g action idSource tid threads wb caps = case action of
  AFork    n a b   -> stepFork        n a b
  AMyTId   c       -> stepMyTId       c
  AGetNumCapabilities   c -> stepGetNumCapabilities c
  ASetNumCapabilities i c -> stepSetNumCapabilities i c
  AYield   c       -> stepYield       c
  ANewVar  n c     -> stepNewVar      n c
  APutVar  var a c -> stepPutVar      var a c
  ATryPutVar var a c -> stepTryPutVar var a c
  AReadVar var c   -> stepReadVar     var c
  ATakeVar var c   -> stepTakeVar     var c
  ATryTakeVar var c -> stepTryTakeVar var c
  ANewRef  n a c   -> stepNewRef      n a c
  AReadRef ref c   -> stepReadRef     ref c
  AReadRefCas ref c -> stepReadRefCas ref c
  AModRef  ref f c -> stepModRef      ref f c
  AModRefCas ref f c -> stepModRefCas ref f c
  AWriteRef ref a c -> stepWriteRef   ref a c
  ACasRef ref tick a c -> stepCasRef ref tick a c
  ACommit  t c     -> stepCommit      t c
  AAtom    stm c   -> stepAtom        stm c
  ALift    na      -> stepLift        na
  AThrow   e       -> stepThrow       e
  AThrowTo t e c   -> stepThrowTo     t e c
  ACatching h ma c -> stepCatching    h ma c
  APopCatching a   -> stepPopCatching a
  AMasking m ma c  -> stepMasking     m ma c
  AResetMask b1 b2 m c -> stepResetMask b1 b2 m c
  AReturn     c    -> stepReturn c
  AMessage    m c  -> stepMessage m c
  AStop       na   -> stepStop na
  ASub        ma k -> stepSubconcurrency ma k

  where
    -- | Start a new thread, assigning it the next 'ThreadId'
    --
    -- Explicit type signature needed for GHC 8. Looks like the
    -- impredicative polymorphism checks got stronger.
    stepFork :: String
             -> ((forall b. M n r s b -> M n r s b) -> Action n r s)
             -> (ThreadId -> Action n r s)
             -> n (Either Failure (Threads n r s, IdSource, Either z ThreadAction, WriteBuffer r, Int, Maybe g))
    stepFork n a b = return $ Right (goto (b newtid) tid threads', idSource', Right (Fork newtid), wb, caps, Nothing) where
      threads' = launch tid newtid a threads
      (idSource', newtid) = nextTId n idSource

    -- | Get the 'ThreadId' of the current thread
    stepMyTId c = simple (goto (c tid) tid threads) MyThreadId

    -- | Get the number of capabilities
    stepGetNumCapabilities c = simple (goto (c caps) tid threads) $ GetNumCapabilities caps

    -- | Set the number of capabilities
    stepSetNumCapabilities i c = return $ Right (goto c tid threads, idSource, Right (SetNumCapabilities i), wb, i, Nothing)

    -- | Yield the current thread
    stepYield c = simple (goto c tid threads) Yield

    -- | Put a value into a @MVar@, blocking the thread until it's
    -- empty.
    stepPutVar cvar@(MVar cvid _) a c = synchronised $ do
      (success, threads', woken) <- putIntoMVar cvar a c tid threads
      simple threads' $ if success then PutVar cvid woken else BlockedPutVar cvid

    -- | Try to put a value into a @MVar@, without blocking.
    stepTryPutVar cvar@(MVar cvid _) a c = synchronised $ do
      (success, threads', woken) <- tryPutIntoMVar cvar a c tid threads
      simple threads' $ TryPutVar cvid success woken

    -- | Get the value from a @MVar@, without emptying, blocking the
    -- thread until it's full.
    stepReadVar cvar@(MVar cvid _) c = synchronised $ do
      (success, threads', _) <- readFromMVar cvar c tid threads
      simple threads' $ if success then ReadVar cvid else BlockedReadVar cvid

    -- | Take the value from a @MVar@, blocking the thread until it's
    -- full.
    stepTakeVar cvar@(MVar cvid _) c = synchronised $ do
      (success, threads', woken) <- takeFromMVar cvar c tid threads
      simple threads' $ if success then TakeVar cvid woken else BlockedTakeVar cvid

    -- | Try to take the value from a @MVar@, without blocking.
    stepTryTakeVar cvar@(MVar cvid _) c = synchronised $ do
      (success, threads', woken) <- tryTakeFromMVar cvar c tid threads
      simple threads' $ TryTakeVar cvid success woken

    -- | Read from a @CRef@.
    stepReadRef cref@(CRef crid _) c = do
      val <- readCRef cref tid
      simple (goto (c val) tid threads) $ ReadRef crid

    -- | Read from a @CRef@ for future compare-and-swap operations.
    stepReadRefCas cref@(CRef crid _) c = do
      tick <- readForTicket cref tid
      simple (goto (c tick) tid threads) $ ReadRefCas crid

    -- | Modify a @CRef@.
    stepModRef cref@(CRef crid _) f c = synchronised $ do
      (new, val) <- f <$> readCRef cref tid
      writeImmediate cref new
      simple (goto (c val) tid threads) $ ModRef crid

    -- | Modify a @CRef@ using a compare-and-swap.
    stepModRefCas cref@(CRef crid _) f c = synchronised $ do
      tick@(Ticket _ _ old) <- readForTicket cref tid
      let (new, val) = f old
      void $ casCRef cref tid tick new
      simple (goto (c val) tid threads) $ ModRefCas crid

    -- | Write to a @CRef@ without synchronising
    stepWriteRef cref@(CRef crid _) a c = case memtype of
      -- Write immediately.
      SequentialConsistency -> do
        writeImmediate cref a
        simple (goto c tid threads) $ WriteRef crid

      -- Add to buffer using thread id.
      TotalStoreOrder -> do
        wb' <- bufferWrite wb (tid, Nothing) cref a
        return $ Right (goto c tid threads, idSource, Right (WriteRef crid), wb', caps, Nothing)

      -- Add to buffer using both thread id and cref id
      PartialStoreOrder -> do
        wb' <- bufferWrite wb (tid, Just crid) cref a
        return $ Right (goto c tid threads, idSource, Right (WriteRef crid), wb', caps, Nothing)

    -- | Perform a compare-and-swap on a @CRef@.
    stepCasRef cref@(CRef crid _) tick a c = synchronised $ do
      (suc, tick') <- casCRef cref tid tick a
      simple (goto (c (suc, tick')) tid threads) $ CasRef crid suc

    -- | Commit a @CRef@ write
    stepCommit t c = do
      wb' <- case memtype of
        -- Shouldn't ever get here
        SequentialConsistency ->
          error "Attempting to commit under SequentialConsistency"

        -- Commit using the thread id.
        TotalStoreOrder -> commitWrite wb (t, Nothing)

        -- Commit using the cref id.
        PartialStoreOrder -> commitWrite wb (t, Just c)

      return $ Right (threads, idSource, Right (CommitRef t c), wb', caps, Nothing)

    -- | Run a STM transaction atomically.
    stepAtom stm c = synchronised $ do
      (res, idSource', trace) <- runstm stm idSource
      case res of
        Success _ written val ->
          let (threads', woken) = wake (OnTVar written) threads
          in return $ Right (goto (c val) tid threads', idSource', Right (STM trace woken), wb, caps, Nothing)
        Retry touched ->
          let threads' = block (OnTVar touched) tid threads
          in return $ Right (threads', idSource', Right (BlockedSTM trace), wb, caps, Nothing)
        Exception e -> do
          res' <- stepThrow e
          return $ case res' of
            Right (threads', _, _, _, _, _) -> Right (threads', idSource', Right Throw, wb, caps, Nothing)
            Left err -> Left err

    -- | Run a subcomputation in an exception-catching context.
    stepCatching h ma c = simple threads' Catching where
      a     = runCont ma      (APopCatching . c)
      e exc = runCont (h exc) (APopCatching . c)

      threads' = goto a tid (catching e tid threads)

    -- | Pop the top exception handler from the thread's stack.
    stepPopCatching a = simple threads' PopCatching where
      threads' = goto a tid (uncatching tid threads)

    -- | Throw an exception, and propagate it to the appropriate
    -- handler.
    stepThrow e =
      case propagate (toException e) tid threads of
        Just threads' -> simple threads' Throw
        Nothing -> return $ Left UncaughtException

    -- | Throw an exception to the target thread, and propagate it to
    -- the appropriate handler.
    stepThrowTo t e c = synchronised $
      let threads' = goto c tid threads
          blocked  = block (OnMask t) tid threads
      in case M.lookup t threads of
           Just thread
             | interruptible thread -> case propagate (toException e) t threads' of
               Just threads'' -> simple threads'' $ ThrowTo t
               Nothing
                 | t == initialThread -> return $ Left UncaughtException
                 | otherwise -> simple (kill t threads') $ ThrowTo t
             | otherwise -> simple blocked $ BlockedThrowTo t
           Nothing -> simple threads' $ ThrowTo t

    -- | Execute a subcomputation with a new masking state, and give
    -- it a function to run a computation with the current masking
    -- state.
    --
    -- Explicit type sig necessary for checking in the prescence of
    -- 'umask', sadly.
    stepMasking :: MaskingState
                -> ((forall b. M n r s b -> M n r s b) -> M n r s a)
                -> (a -> Action n r s)
                -> n (Either Failure (Threads n r s, IdSource, Either z ThreadAction, WriteBuffer r, Int, Maybe g))
    stepMasking m ma c = simple threads' $ SetMasking False m where
      a = runCont (ma umask) (AResetMask False False m' . c)

      m' = _masking . fromJust $ M.lookup tid threads
      umask mb = resetMask True m' >> mb >>= \b -> resetMask False m >> return b
      resetMask typ ms = cont $ \k -> AResetMask typ True ms $ k ()

      threads' = goto a tid (mask m tid threads)

    -- | Reset the masking thread of the state.
    stepResetMask b1 b2 m c = simple threads' act where
      act      = (if b1 then SetMasking else ResetMasking) b2 m
      threads' = goto c tid (mask m tid threads)

    -- | Create a new @MVar@, using the next 'MVarId'.
    stepNewVar n c = do
      let (idSource', newmvid) = nextMVId n idSource
      ref <- newRef Nothing
      let mvar = MVar newmvid ref
      return $ Right (goto (c mvar) tid threads, idSource', Right (NewVar newmvid), wb, caps, Nothing)

    -- | Create a new @CRef@, using the next 'CRefId'.
    stepNewRef n a c = do
      let (idSource', newcrid) = nextCRId n idSource
      ref <- newRef (M.empty, 0, a)
      let cref = CRef newcrid ref
      return $ Right (goto (c cref) tid threads, idSource', Right (NewRef newcrid), wb, caps, Nothing)

    -- | Lift an action from the underlying monad into the @Conc@
    -- computation.
    stepLift na = do
      a <- na
      simple (goto a tid threads) LiftIO

    -- | Execute a 'return' or 'pure'.
    stepReturn c = simple (goto c tid threads) Return

    -- | Add a message to the trace.
    stepMessage m c = simple (goto c tid threads) (Message m)

    -- | Kill the current thread.
    stepStop na = na >> simple (kill tid threads) Stop

    -- | Run a subconcurrent computation.
    stepSubconcurrency ma c
      | M.size threads > 1 = return (Left IllegalSubconcurrency)
      | otherwise = do
          (res, g', trace) <- runConcurrency runstm sched memtype g ma
          return $ Right (goto (c res) tid threads, idSource, Left (Subconcurrency, trace), wb, caps, Just g')

    -- | Helper for actions which don't touch the 'IdSource' or
    -- 'WriteBuffer'
    simple threads' act = return $ Right (threads', idSource, Right act, wb, caps, Nothing)

    -- | Helper for actions impose a write barrier.
    synchronised ma = do
      writeBarrier wb
      res <- ma

      return $ case res of
        Right (threads', idSource', act', _, caps', g') -> Right (threads', idSource', act', emptyBuffer, caps', g')
        _ -> res
