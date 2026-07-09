# stateMachine
A clean and easy-to-use state machine library for Luau. Perfect for managing character states, UI flows, game modes, and complex behaviors in Roblox experiences.

## Usage
```lua
local RunService = game:GetService("RunService")
local stateMachine = require(Packages.stateMachine)

-- Some State
local someState = stateMachine.newState("some") :: stateMachine.State<{ message: string }>

function someState:update<context>(context: context)
    print(string.format("Message: %s from state: %s", context.message, self.name))
end

-- State Machine
local machine = stateMachine.newStateMachine() :: stateMachine.StateMachine<{ message: string }, number>

machine:registerState(someState)
machine:setInitialState("someState")
machine:bindUpdate(RunService.Heartbeat)
```
