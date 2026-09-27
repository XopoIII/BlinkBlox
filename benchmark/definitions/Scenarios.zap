opt server_output = "../runtime/rivals/zap/Server.luau"
opt client_output = "../runtime/rivals/zap/Client.luau"

-- Scenarios.blink's events, as zap declares them; see benchmark/Rivals.luau.

type Unit = struct {
    id: u16,
    x: f32,
    y: f32,
    z: f32,
    health: u8,
    moving: boolean,
    crouched: boolean
}

event Snapshot = {
    from: Server,
    type: Reliable,
    call: SingleSync,
    data: Unit
}

event Input = {
    from: Client,
    type: Unreliable,
    call: SingleSync,
    data: struct { move: u8, turn: i16, jump: boolean, sprint: boolean }
}

event Touch = {
    from: Client,
    type: Reliable,
    call: SingleSync,
    data: struct { part: Instance, force: u8 }
}

event WorldState = {
    from: Server,
    type: Unreliable,
    call: SingleSync,
    data: Unit[0..16]
}

event SelfState = {
    from: Server,
    type: Unreliable,
    call: SingleSync,
    data: Unit
}
