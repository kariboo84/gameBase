/**
	Inputs of one local player: its own Controller, with its own keyboard and gamepad bindings.
	Gamepads are given to players by the `PadDispatcher` in App (first pad to press a button goes to player 0, etc.)
**/
class PlayerInput {
	/** Player index, starting at 0 **/
	public var index(default,null) : Int;

	/** Controller owning this player bindings. Use `controller.createAccess()` to read it. **/
	public var controller(default,null) : Controller<GameAction>;

	/** TRUE if a physical gamepad is currently assigned to this player **/
	public var hasPad(get,never) : Bool;
		inline function get_hasPad() return controller.isPadConnected();


	public function new(index:Int) {
		this.index = index;
		controller = Controller.createFromAbstractEnum(GameAction, false);
		initBindings();
	}


	/** Gameplay bindings of this player **/
	public function initBindings() {
		controller.removeBindings();

		// Gamepad (every player)
		controller.bindPadLStick4(MoveLeft, MoveRight, MoveUp, MoveDown);
		controller.bindPad(MoveLeft, DPAD_LEFT);
		controller.bindPad(MoveRight, DPAD_RIGHT);
		controller.bindPad(MoveUp, DPAD_UP);
		controller.bindPad(MoveDown, DPAD_DOWN);
		controller.bindPad(Jump, A);

		// Keyboard (each player owns a distinct set of keys)
		switch index {
			case 0:
				controller.bindKeyboard(MoveLeft, [K.Q, K.A]);
				controller.bindKeyboard(MoveRight, K.D);
				controller.bindKeyboard(MoveUp, [K.Z, K.W]);
				controller.bindKeyboard(MoveDown, K.S);
				controller.bindKeyboard(Jump, K.SPACE);

			case 1:
				controller.bindKeyboard(MoveLeft, K.LEFT);
				controller.bindKeyboard(MoveRight, K.RIGHT);
				controller.bindKeyboard(MoveUp, K.UP);
				controller.bindKeyboard(MoveDown, K.DOWN);
				controller.bindKeyboard(Jump, [K.UP, K.NUMPAD_0]);

			case _:
				// No keyboard keys for other players: gamepad only
		}
	}


	public function dispose() {
		controller.dispose();
		controller = null;
	}
}
