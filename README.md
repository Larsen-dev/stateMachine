# stateMachine
Roblox FSM (Finite State Machine) for small projects and simple systems. Yet still incomplete and edgy, so there's
no Wally package or .rbxm file. Gotta be soon.

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
machine:requestTransition("someState")
machine:bindUpdate(RunService.Heartbeat)
```
