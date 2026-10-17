--!strict
-- 서버 진입점. 부팅 순서: Remotes.init -> DevMap.ensure -> GameFlow.start (CONTRACT 3절)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local DevMap = require(script.Parent.DevMap)
local GameFlow = require(script.Parent.GameFlow)

Remotes.init()
DevMap.ensure()
GameFlow.start()
