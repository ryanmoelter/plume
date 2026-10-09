typealias GRPCInputEvent = Android_Emulation_Control_InputEvent

enum InputEncoding {
    static func event(for input: EmulatorInput) -> GRPCInputEvent {
        var event = GRPCInputEvent()
        switch input {
        case .touch(let points):
            var touch = Android_Emulation_Control_TouchEvent()
            touch.touches = points.map { point in
                var t = Android_Emulation_Control_Touch()
                t.x = point.x
                t.y = point.y
                t.identifier = point.identifier
                t.pressure = point.pressure
                return t
            }
            event.touchEvent = touch
        case .mouse(let x, let y, let buttons):
            var mouse = Android_Emulation_Control_MouseEvent()
            mouse.x = x
            mouse.y = y
            mouse.buttons = buttons
            event.mouseEvent = mouse
        case .wheel(let dx, let dy):
            var wheel = Android_Emulation_Control_WheelEvent()
            wheel.dx = dx
            wheel.dy = dy
            event.wheelEvent = wheel
        case .key(let key):
            event.keyEvent = keyboardEvent(for: key)
        }
        return event
    }

    static func buttonEvent(_ button: HardwareButton, phase: KeyPhase) -> GRPCInputEvent {
        var event = GRPCInputEvent()
        if let evdev = button.evdevKeyCode {
            event.keyEvent = keyboardEvent(for: .evdev(keyCode: evdev, phase: phase))
        } else {
            event.keyEvent = keyboardEvent(for: .named(button.rawValue, phase: phase))
        }
        return event
    }

    private static func keyboardEvent(for key: KeyInput) -> Android_Emulation_Control_KeyboardEvent {
        var event = Android_Emulation_Control_KeyboardEvent()
        switch key {
        case .mac(let keyCode, let phase):
            event.codeType = .mac
            event.keyCode = keyCode
            event.eventType = eventType(phase)
        case .evdev(let keyCode, let phase):
            event.codeType = .evdev
            event.keyCode = keyCode
            event.eventType = eventType(phase)
        case .named(let name, let phase):
            event.key = name
            event.eventType = eventType(phase)
        case .text(let text):
            event.text = text
        }
        return event
    }

    private static func eventType(_ phase: KeyPhase) -> Android_Emulation_Control_KeyboardEvent.KeyEventType {
        switch phase {
        case .down: .keydown
        case .up: .keyup
        case .press: .keypress
        }
    }
}
