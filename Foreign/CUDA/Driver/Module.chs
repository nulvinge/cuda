{-# LANGUAGE ForeignFunctionInterface #-}
--------------------------------------------------------------------------------
-- |
-- Module    : Foreign.CUDA.Driver.Module
-- Copyright : (c) [2009..2010] Trevor L. McDonell
-- License   : BSD
--
-- Module management for low-level driver interface
--
--------------------------------------------------------------------------------

module Foreign.CUDA.Driver.Module
  (
    Module,
    JITOption(..), JITTarget(..), JITResult(..),
    getFun, getPtr, getTex,
    loadFile, loadData, loadDataEx, unload
  )
  where

#include <cuda.h>
{# context lib="cuda" #}

-- Friends
import Foreign.CUDA.Ptr
import Foreign.CUDA.Driver.Error
import Foreign.CUDA.Driver.Exec
import Foreign.CUDA.Driver.Texture
import Foreign.CUDA.Internal.C2HS

-- System
import Foreign
import Foreign.C
import Unsafe.Coerce

import Control.Applicative
import Control.Monad                            (liftM)
import Data.ByteString.Char8                    (ByteString)
import qualified Data.ByteString.Char8 as B


--------------------------------------------------------------------------------
-- Data Types
--------------------------------------------------------------------------------

-- |
-- A reference to a Module object, containing collections of device functions
--
newtype Module = Module { useModule :: {# type CUmodule #}}


-- |
-- Just-in-time compilation options
--
data JITOption
  = MaxRegisters       Int       -- ^ maximum number of registers per thread
  | ThreadsPerBlock    Int       -- ^ number of threads per block to target for
  | OptimisationLevel  Int       -- ^ level of optimisation to apply (1-4, default 4)
  | Target             JITTarget -- ^ compilation target, otherwise determined from context
--  | FallbackStrategy   JITFallback
  deriving (Show)

-- |
-- Results of online compilation
--
data JITResult = JITResult
  {
    jitTime     :: Float,       -- ^ milliseconds spent compiling PTX
    jitInfoLog  :: ByteString,  -- ^ information about PTX asembly
    jitErrorLog :: ByteString   -- ^ compilation errors
  }
  deriving (Show)


{# enum CUjit_option as JITOptionInternal
    { }
    with prefix="CU" deriving (Eq, Show) #}

{# enum CUjit_target as JITTarget
    { underscoreToCase }
    with prefix="CU_TARGET" deriving (Eq, Show) #}

{# enum CUjit_fallback as JITFallback
    { underscoreToCase }
    with prefix="CU_PREFER" deriving (Eq, Show) #}


--------------------------------------------------------------------------------
-- Module management
--------------------------------------------------------------------------------

-- |
-- Returns a function handle
--
getFun :: Module -> String -> IO Fun
getFun mdl fn = resultIfOk =<< cuModuleGetFunction mdl fn

{# fun unsafe cuModuleGetFunction
  { alloca-      `Fun'    peekFun*
  , useModule    `Module'
  , withCString* `String'          } -> `Status' cToEnum #}
  where peekFun = liftM Fun . peek


-- |
-- Return a global pointer, and size of the global (in bytes)
--
getPtr :: Module -> String -> IO (DevicePtr a, Int)
getPtr mdl name = do
  (status,dptr,bytes) <- cuModuleGetGlobal mdl name
  resultIfOk (status,(dptr,bytes))

{# fun unsafe cuModuleGetGlobal
  { alloca-      `DevicePtr a' peekDevPtr*
  , alloca-      `Int'         peekIntConv*
  , useModule    `Module'
  , withCString* `String'                   } -> `Status' cToEnum #}
  where
    peekDevPtr p = DevicePtr . intPtrToPtr . fromIntegral <$> peek p


-- |
-- Return a handle to a texture reference
--
getTex :: Module -> String -> IO Texture
getTex mdl name = resultIfOk =<< cuModuleGetTexRef mdl name

{# fun unsafe cuModuleGetTexRef
  { alloca-      `Texture' peekTex*
  , useModule    `Module'
  , withCString* `String'           } -> `Status' cToEnum #}
  where peekTex = liftM Texture . peek


-- |
-- Load the contents of the specified file (either a ptx or cubin file) to
-- create a new module, and load that module into the current context
--
loadFile :: String -> IO Module
loadFile ptx = resultIfOk =<< cuModuleLoad ptx

{# fun unsafe cuModuleLoad
  { alloca-      `Module' peekMod*
  , withCString* `String'          } -> `Status' cToEnum #}
  where peekMod = liftM Module . peek


-- |
-- Load the contents of the given image into a new module, and load that module
-- into the current context. The image (typically) is the contents of a cubin or
-- ptx file as a NULL-terminated string.
--
loadData :: ByteString -> IO Module
loadData img = resultIfOk =<< cuModuleLoadData img

{# fun unsafe cuModuleLoadData
  { alloca- `Module'     peekMod*
  , useBS*  `ByteString'          } -> ` Status' cToEnum #}
  where
    peekMod      = liftM Module . peek
    useBS bs act = B.useAsCString bs $ \p -> act (castPtr p)


-- |
-- Load a module with online compiler options. The actual attributes of the
-- compiled kernel can be probed using `requirements'.
--
loadDataEx :: ByteString -> [JITOption] -> IO (Module, JITResult)
loadDataEx img options =
  allocaArray logSize $ \p_ilog ->
  allocaArray logSize $ \p_elog ->
  let (opt,val) = unzip $
        [ (JIT_WALL_TIME, 0) -- must be first
        , (JIT_INFO_LOG_BUFFER_SIZE_BYTES,  logSize)
        , (JIT_ERROR_LOG_BUFFER_SIZE_BYTES, logSize)
        , (JIT_INFO_LOG_BUFFER,  unsafeCoerce (p_ilog :: CString))
        , (JIT_ERROR_LOG_BUFFER, unsafeCoerce (p_elog :: CString)) ] ++ map unpack options in

  withArray (map cFromEnum opt)    $ \p_opts ->
  withArray (map unsafeCoerce val) $ \p_vals -> do

  (s,mdl) <- cuModuleLoadDataEx img (length opt) p_opts p_vals
  infoLog <- B.packCString p_ilog
  errLog  <- B.packCString p_elog
  time    <- peek (castPtr p_vals)
  resultIfOk (s, (mdl, JITResult time infoLog errLog))

  where
    logSize = 2048

    unpack (MaxRegisters x)      = (JIT_MAX_REGISTERS, x)
    unpack (ThreadsPerBlock x)   = (JIT_THREADS_PER_BLOCK, x)
    unpack (OptimisationLevel x) = (JIT_OPTIMIZATION_LEVEL, x)
    unpack (Target x)            = (JIT_TARGET, fromEnum x)


{# fun unsafe cuModuleLoadDataEx
  { alloca- `Module'       peekMod*
  , useBS*  `ByteString'
  ,         `Int'
  , id      `Ptr CInt'
  , id      `Ptr (Ptr ())'          } -> `Status' cToEnum #}
  where
    peekMod      = liftM Module . peek
    useBS bs act = B.useAsCString bs $ \p -> act (castPtr p)


-- |
-- Unload a module from the current context
--
unload :: Module -> IO ()
unload m = nothingIfOk =<< cuModuleUnload m

{# fun unsafe cuModuleUnload
  { useModule `Module' } -> `Status' cToEnum #}

