{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-
Copyright © 2017 Albert Krewinkel <tarleb+pandoc@moltkeplatz.de>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}
{- |
   Module      : Text.Pandoc.Lua
   Copyright   : Copyright © 2017 Albert Krewinkel
   License     : GNU GPL, version 2 or above

   Maintainer  : Albert Krewinkel <tarleb+pandoc@moltkeplatz.de>
   Stability   : alpha

Pandoc lua utils.
-}
module Text.Pandoc.Lua ( LuaException(..),
                         runLuaFilter,
                         pushPandocModule ) where

import Control.Exception
import Control.Monad (unless, when, (>=>))
import Control.Monad.Trans (MonadIO (..))
import Data.Map (Map)
import Data.Typeable (Typeable)
import Scripting.Lua (LuaState, StackValue (..))
import Text.Pandoc.Definition
import Text.Pandoc.Lua.PandocModule (pushPandocModule)
import Text.Pandoc.Lua.StackInstances ()
import Text.Pandoc.Walk

import qualified Data.Map as Map
import qualified Scripting.Lua as Lua

newtype LuaException = LuaException String
  deriving (Show, Typeable)

instance Exception LuaException

runLuaFilter :: (MonadIO m)
             => FilePath -> [String] -> Pandoc -> m Pandoc
runLuaFilter filterPath args pd = liftIO $ do
  lua <- Lua.newstate
  Lua.openlibs lua
  -- store module in global "pandoc"
  pushPandocModule lua
  Lua.setglobal lua "pandoc"
  top <- Lua.gettop lua
  status <- Lua.loadfile lua filterPath
  if status /= 0
    then do
      Just luaErrMsg <- Lua.peek lua 1
      throwIO (LuaException luaErrMsg)
    else do
      Lua.call lua 0 Lua.multret
      newtop <- Lua.gettop lua
      -- Use the implicitly defined global filter if nothing was returned
      when (newtop - top < 1) $ pushGlobalFilter lua
      Just luaFilters <- Lua.peek lua (-1)
      Lua.push lua args
      Lua.setglobal lua "PandocParameters"
      doc <- runAll luaFilters pd
      Lua.close lua
      return doc

pushGlobalFilter :: LuaState -> IO ()
pushGlobalFilter lua =
  Lua.newtable lua
  *> Lua.getglobal2 lua "pandoc.global_filter"
  *> Lua.call lua 0 1
  *> Lua.rawseti lua (-2) 1

runAll :: [LuaFilter] -> Pandoc -> IO Pandoc
runAll = foldr ((>=>) . walkMWithLuaFilter) return

walkMWithLuaFilter :: LuaFilter -> Pandoc -> IO Pandoc
walkMWithLuaFilter (LuaFilter lua fnMap) =
  walkM (execInlineLuaFilter lua fnMap) >=>
  walkM (execBlockLuaFilter  lua fnMap) >=>
  walkM (execMetaLuaFilter   lua fnMap) >=>
  walkM (execDocLuaFilter    lua fnMap)

type FunctionMap = Map String LuaFilterFunction
data LuaFilter = LuaFilter LuaState FunctionMap

newtype LuaFilterFunction = LuaFilterFunction { functionIndex :: Int }

execDocLuaFilter :: LuaState
                 -> FunctionMap
                 -> Pandoc -> IO Pandoc
execDocLuaFilter lua fnMap x = do
  let docFnName = "Doc"
  case Map.lookup docFnName fnMap of
    Nothing -> return x
    Just fn -> runFilterFunction lua fn x

execMetaLuaFilter :: LuaState
                  -> FunctionMap
                  -> Pandoc -> IO Pandoc
execMetaLuaFilter lua fnMap pd@(Pandoc meta blks) = do
  let metaFnName = "Meta"
  case Map.lookup metaFnName fnMap of
    Nothing -> return pd
    Just fn -> do
      meta' <- runFilterFunction lua fn meta
      return $ Pandoc meta' blks

execBlockLuaFilter :: LuaState
                   -> FunctionMap
                   -> Block -> IO Block
execBlockLuaFilter lua fnMap x = do
  let tryFilter :: String -> IO Block
      tryFilter filterFnName =
        case Map.lookup filterFnName fnMap of
          Nothing -> return x
          Just fn -> runFilterFunction lua fn x
  case x of
    BlockQuote{}     -> tryFilter "BlockQuote"
    BulletList{}     -> tryFilter "BulletList"
    CodeBlock{}      -> tryFilter "CodeBlock"
    DefinitionList{} -> tryFilter "DefinitionList"
    Div{}            -> tryFilter "Div"
    Header{}         -> tryFilter "Header"
    HorizontalRule   -> tryFilter "HorizontalRule"
    LineBlock{}      -> tryFilter "LineBlock"
    Null             -> tryFilter "Null"
    Para{}           -> tryFilter "Para"
    Plain{}          -> tryFilter "Plain"
    RawBlock{}       -> tryFilter "RawBlock"
    OrderedList{}    -> tryFilter "OrderedList"
    Table{}          -> tryFilter "Table"

execInlineLuaFilter :: LuaState
                    -> FunctionMap
                    -> Inline -> IO Inline
execInlineLuaFilter lua fnMap x = do
  let tryFilter :: String -> IO Inline
      tryFilter filterFnName =
        case Map.lookup filterFnName fnMap of
          Nothing -> return x
          Just fn -> runFilterFunction lua fn x
  let tryFilterAlternatives :: [String] -> IO Inline
      tryFilterAlternatives [] = return x
      tryFilterAlternatives (fnName : alternatives) =
        case Map.lookup fnName fnMap of
          Nothing -> tryFilterAlternatives alternatives
          Just fn -> runFilterFunction lua fn x
  case x of
    Cite{}               -> tryFilter "Cite"
    Code{}               -> tryFilter "Code"
    Emph{}               -> tryFilter "Emph"
    Image{}              -> tryFilter "Image"
    LineBreak            -> tryFilter "LineBreak"
    Link{}               -> tryFilter "Link"
    Math DisplayMath _   -> tryFilterAlternatives ["DisplayMath", "Math"]
    Math InlineMath _    -> tryFilterAlternatives ["InlineMath", "Math"]
    Note{}               -> tryFilter "Note"
    Quoted DoubleQuote _ -> tryFilterAlternatives ["DoubleQuoted", "Quoted"]
    Quoted SingleQuote _ -> tryFilterAlternatives ["SingleQuoted", "Quoted"]
    RawInline{}          -> tryFilter "RawInline"
    SmallCaps{}          -> tryFilter "SmallCaps"
    SoftBreak            -> tryFilter "SoftBreak"
    Space                -> tryFilter "Space"
    Span{}               -> tryFilter "Span"
    Str{}                -> tryFilter "Str"
    Strikeout{}          -> tryFilter "Strikeout"
    Strong{}             -> tryFilter "Strong"
    Subscript{}          -> tryFilter "Subscript"
    Superscript{}        -> tryFilter "Superscript"

instance StackValue LuaFilter where
  valuetype _ = Lua.TTABLE
  push = undefined
  peek lua idx = fmap (LuaFilter lua) <$> Lua.peek lua idx

-- | Helper class for pushing a single value to the stack via a lua function.
-- See @pushViaCall@.
class PushViaFilterFunction a where
  pushViaFilterFunction' :: LuaState -> LuaFilterFunction -> IO () -> Int -> a

instance StackValue a => PushViaFilterFunction (IO a) where
  pushViaFilterFunction' lua lf pushArgs num = do
    pushFilterFunction lua lf
    pushArgs
    Lua.call lua num 1
    mbres <- Lua.peek lua (-1)
    case mbres of
      Nothing -> throwIO $ LuaException
                  ("Error while trying to get a filter's return "
                   ++ "value from lua stack.")
      Just res -> res <$ Lua.pop lua 1

instance (StackValue a, PushViaFilterFunction b) =>
         PushViaFilterFunction (a -> b) where
  pushViaFilterFunction' lua lf pushArgs num x =
    pushViaFilterFunction' lua lf (pushArgs *> push lua x) (num + 1)

-- | Push a value to the stack via a lua filter function. The filter function is
-- called with all arguments that are passed to this function and is expected to
-- return a single value.
runFilterFunction :: PushViaFilterFunction a
                     => LuaState -> LuaFilterFunction -> a
runFilterFunction lua lf = pushViaFilterFunction' lua lf (return ()) 0

-- | Push the filter function to the top of the stack.
pushFilterFunction :: Lua.LuaState -> LuaFilterFunction -> IO ()
pushFilterFunction lua lf =
  -- The function is stored in a lua registry table, retrieve it from there.
  Lua.rawgeti lua Lua.registryindex (functionIndex lf)

registerFilterFunction :: LuaState -> Int -> IO LuaFilterFunction
registerFilterFunction lua idx = do
  isFn <- Lua.isfunction lua idx
  unless isFn . throwIO . LuaException $ "Not a function at index " ++ show idx
  Lua.pushvalue lua idx
  refIdx <- Lua.ref lua Lua.registryindex
  return $ LuaFilterFunction refIdx

instance StackValue LuaFilterFunction where
  valuetype _ = Lua.TFUNCTION
  push = pushFilterFunction
  peek = fmap (fmap Just) . registerFilterFunction
