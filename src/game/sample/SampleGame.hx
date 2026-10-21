package sample;

/**
	This small class creates a SamplePlayer for player 1 in current level.
	Other local players join the game by pressing their Jump input (keyboard or gamepad).
**/
class SampleGame extends Game {
	var heroes : Array<SamplePlayer> = [];
	var joinAccesses : Array<ControllerAccess<GameAction>> = [];
	var fixedFrameCount = 0;

	public function new() {
		super();

		for(p in App.ME.players) {
			var joinCa = p.controller.createAccess();
			joinCa.lockCondition = Game.isGameControllerLocked;
			joinAccesses.push(joinCa);
		}
	}

	override function startLevel(l:World_Level) {
		super.startLevel(l);
		heroes = [];
		spawnPlayer(App.ME.players[0]);
	}

	function spawnPlayer(p:PlayerInput) {
		var hero = new SamplePlayer(p);
		if( heroes.length>0 )
			hero.setPosCase(heroes[0].cx, heroes[0].cy);
		heroes.push(hero);
	}

	function hasJoined(p:PlayerInput) {
		for(h in heroes)
			if( h.player==p && !h.destroyed )
				return true;
		return false;
	}

	override function update() {
		super.update();
		if( destroyed ) // eg. game restarted during super.update()
			return;

		// Other players join by pressing Jump
		for(p in App.ME.players)
			if( !hasJoined(p) && joinAccesses[p.index].isPressed(Jump) )
				spawnPlayer(p);
	}

	override function fixedUpdate() {
		super.fixedUpdate();
		fixedFrameCount++;
		if( destroyed )
			return;

		// Players standing on other players follow them, once everyone has moved
		for(h in heroes)
			if( !h.destroyed )
				h.applyCarry(fixedFrameCount);
	}

	override function onDispose() {
		super.onDispose();
		for(ca in joinAccesses)
			ca.dispose();
		joinAccesses = [];
	}
}

