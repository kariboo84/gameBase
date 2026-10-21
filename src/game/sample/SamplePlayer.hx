package sample;

/**
	SamplePlayer is an Entity with some extra functionalities:
	- user controlled (using gamepad or keyboard)
	- falls with gravity
	- has basic level collisions
	- some squash animations, because it's cheap and they do the job
**/

class SamplePlayer extends Entity {
	public var player(default,null) : PlayerInput;
	var ca : ControllerAccess<GameAction>;
	var walkSpeed = 0.;

	/** Other player this one is standing on (and carried by), if any **/
	var carrier : Null<SamplePlayer>;
	var carryDoneFrame = -1;

	// This is TRUE if the player is not falling (standing on the level or on another player's head)
	var onGround(get,never) : Bool;
		inline function get_onGround() return !destroyed && ( isCarried() || vBase.dy==0 && yr==1 && level.hasCollision(cx,cy+1) );

	/** Y coordinate (pixels) of the top of the head **/
	public var headY(get,never) : Float;
		inline function get_headY() return attachY - hei;


	public function new(player:PlayerInput) {
		super(5,5);
		this.player = player;

		// Start point using level entity "PlayerStart"
		var start = level.data.l_Entities.all_PlayerStart[0];
		if( start!=null )
			setPosCase(start.cx, start.cy);

		// Misc inits
		vBase.setFricts(0.84, 0.94);

		// Camera tracks the first player only (multiplayer camera is game dependent)
		if( player.index==0 )
			camera.trackEntity(this, true);
		camera.clampToLevelBounds = true;

		// Init controller
		ca = player.controller.createAccess();
		ca.lockCondition = Game.isGameControllerLocked;

		// Placeholder display
		var b = new h2d.Bitmap( h2d.Tile.fromColor(getPlayerColor(), iwid, ihei), spr );
		b.tile.setCenterRatio(0.5,1);
	}


	public function getPlayerColor() : Col {
		return switch player.index {
			case 0: Green;
			case 1: Blue;
			case 2: Red;
			case _: Yellow;
		}
	}


	override function dispose() {
		super.dispose();
		carrier = null;
		ca.dispose(); // don't forget to dispose controller accesses
	}


	/** X collisions **/
	override function onPreStepX() {
		super.onPreStepX();

		// Right collision
		if( xr>0.8 && level.hasCollision(cx+1,cy) )
			xr = 0.8;

		// Left collision
		if( xr<0.2 && level.hasCollision(cx-1,cy) )
			xr = 0.2;
	}


	public inline function isCarried() {
		return carrier!=null;
	}


	/** TRUE if both players horizontally overlap enough to stand on each other **/
	inline function overlapsX(other:SamplePlayer) {
		return M.fabs(attachX-other.attachX) < (wid+other.wid)*0.5 - 2;
	}


	/** TRUE if `other` is carried by this player, directly or through a stack **/
	function isCarrying(other:SamplePlayer) {
		var e = other.carrier;
		while( e!=null ) {
			if( e==this )
				return true;
			e = e.carrier;
		}
		return false;
	}


	/** Return the player whose head we just reached while falling, if any **/
	function findHeadToLandOn() : Null<SamplePlayer> {
		for(e in Entity.ALL) {
			var other = Std.downcast(e, SamplePlayer);
			if( other==null || other==this || other.destroyed || isCarrying(other) )
				continue;

			var wasAboveHead = lastFixedUpdateY <= other.headY + 0.5;
			var reachedHead = attachY >= other.headY;
			if( overlapsX(other) && wasAboveHead && reachedHead )
				return other;
		}
		return null;
	}


	function startCarriedBy(other:SamplePlayer) {
		carrier = other;
		vBase.clearY();
		vBump.clearY();
		setFeetY(other.headY);
		setSquashY(0.6);
		ca.rumble(0.1, 0.06);
	}


	function stopCarried() {
		carrier = null;
	}


	/** Put feet at given Y pixel coordinate, without collision checks **/
	function setFeetY(y:Float) {
		cy = Std.int(y/Const.GRID);
		yr = (y - cy*Const.GRID) / Const.GRID;
	}


	/**
		Follow the carrier movement. Called by SampleGame after ALL entities fixedUpdate, so that the carrier position for this tick is final.
		The rider position before this call was already recorded by `updateLastFixedUpdatePos()`, so the carry movement is smoothly interpolated.
	**/
	public function applyCarry(fixedFrame:Int) {
		if( carryDoneFrame==fixedFrame )
			return;
		carryDoneFrame = fixedFrame;

		if( !isCarried() )
			return;

		// Stacks: move the carrier first
		carrier.applyCarry(fixedFrame);

		// Jumped, walked off or carrier gone
		if( carrier.destroyed || vBase.dy<0 || !overlapsX(carrier) ) {
			stopCarried();
			return;
		}

		// Horizontal: move along with the carrier, blocked by walls
		xr += ( carrier.attachX - carrier.lastFixedUpdateX ) / Const.GRID;
		while( xr>1 ) { xr--; cx++; }
		while( xr<0 ) { xr++; cx--; }
		if( xr>0.8 && level.hasCollision(cx+1,cy) )
			xr = 0.8;
		if( xr<0.2 && level.hasCollision(cx-1,cy) )
			xr = 0.2;

		// Vertical: stay on the head, unless the head moves into a ceiling
		var feetY = carrier.headY;
		var headCy = Std.int( (feetY-hei) / Const.GRID );
		if( level.hasCollision(cx, headCy) ) {
			stopCarried();
			return;
		}
		setFeetY(feetY);
		vBase.clearY();
	}


	/** Y collisions **/
	override function onPreStepY() {
		super.onPreStepY();

		// Land on another player's head
		if( !isCarried() && dyTotal>0 ) {
			var other = findHeadToLandOn();
			if( other!=null ) {
				startCarriedBy(other);
				return;
			}
		}

		// Land on ground
		if( yr>1 && level.hasCollision(cx,cy+1) ) {
			setSquashY(0.5);
			vBase.clearY();
			vBump.clearY();
			yr = 1;
			ca.rumble(0.2, 0.06);
			onPosManuallyChangedY();
		}

		// Ceiling collision
		if( yr<0.2 && level.hasCollision(cx,cy-1) )
			yr = 0.2;
	}


	/**
		Control inputs are checked at the beginning of the frame.
		VERY IMPORTANT NOTE: because game physics only occur during the `fixedUpdate` (at a constant 30 FPS), no physics increment should ever happen here! What this means is that you can SET a physics value (eg. see the Jump below), but not make any calculation that happens over multiple frames (eg. increment X speed when walking).
	**/
	override function preUpdate() {
		super.preUpdate();

		walkSpeed = 0;
		if( onGround )
			cd.setS("recentlyOnGround",0.1); // allows "just-in-time" jumps


		// Jump
		if( cd.has("recentlyOnGround") && ca.isPressed(Jump) ) {
			vBase.addY(-0.85);
			setSquashX(0.6);
			cd.unset("recentlyOnGround");
			fx.dotsExplosionExample(centerX, centerY, 0xffcc00);
			ca.rumble(0.05, 0.06);
		}

		// Walk
		if( !isChargingAction() && ca.getAnalogDist2(MoveLeft,MoveRight)>0 ) {
			// As mentioned above, we don't touch physics values (eg. `dx`) here. We just store some "requested walk speed", which will be applied to actual physics in fixedUpdate.
			walkSpeed = ca.getAnalogValue2(MoveLeft,MoveRight); // -1 to 1
		}
	}


	override function fixedUpdate() {
		super.fixedUpdate();

		// Gravity
		if( !onGround )
			vBase.addY(0.05);

		// Apply requested walk movement
		if( walkSpeed!=0 )
			vBase.addX( walkSpeed*0.045 ); // some arbitrary speed
	}
}