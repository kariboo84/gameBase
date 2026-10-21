package sample;

/**
	Local multiplayer sample:
	- player 1 is created in the current level,
	- other local players join the game by pressing their Jump input (keyboard or gamepad), [F2] adds an idle test player,
	- the camera follows the group, and the split-screen gives each hero its own view when they move apart,
	- heroes can stand on each other heads (see `SamplePlayer.applyCarry()`).
**/
class SampleGame extends Game {
	/** Heroes in the level, in joining order **/
	var heroes : Array<SamplePlayer> = [];

	/** One access per player, only used to detect "join" presses (heroes have their own accesses once spawned) **/
	var joinAccesses : Array<ControllerAccess<GameAction>> = [];

	/** Number of fixedUpdate calls, used to apply carrying only once per hero and per fixed frame **/
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
		// Late joiners appear next to the first hero
		if( heroes.length>0 )
			hero.setPosCase(heroes[0].cx, heroes[0].cy);
		heroes.push(hero);
		updateCameras();
	}

	/** Shared camera follows the group, split-screen gives each hero its own view when they move apart **/
	function updateCameras() {
		var group : Array<Entity> = [ for(h in heroes) if( h.isAlive() ) h ];
		camera.trackGroup(group, false);
		// Split-screen slices meet at the screen center: the camera must keep the group centered, even if the void beyond level bounds becomes visible
		camera.clampToLevelBounds = group.length<2;
		splitScreen.setTargets(group, [ for(h in heroes) if( h.isAlive() ) h.getPlayerColor() ]);
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

		// Test helper: [F2] adds the next missing player (it stays idle if nobody controls it)
		if( ca.isKeyboardPressed(K.F2) )
			for(p in App.ME.players)
				if( !hasJoined(p) ) {
					spawnPlayer(p);
					break;
				}
	}

	override function fixedUpdate() {
		super.fixedUpdate();
		fixedFrameCount++;
		if( destroyed )
			return;

		// Players standing on other players follow them. This is done after ALL entities fixedUpdate,
		// so that carriers positions are final for this frame, whatever the entities update order.
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

