/**
	Split-screen for local multiplayer.

	- While every target is visible on the shared screen (ie. close enough to the group center), a single screen is displayed.
	- 2 targets: "DBZ" dynamic split. The screen is cut by a line through its center, perpendicular to the direction between the targets.
	  Each target stays on its own side. The transition from shared to split screen is seamless, and the line rotation is smoothed.
	- 3+ targets: fixed quarters, each target always keeps the same one. With 3 targets, the 4th quarter shows a zoomed-out overview of the whole group. Shared/split transitions are short fades, with a hysteresis to avoid flickering.

	The game scroller is rendered once per view into an offscreen texture (same pixel-perfect scale), then a shader composes the final image and draws the separators.
	The main `Camera` should track the same group (`camera.trackGroup(...)`), WITHOUT level bounds clamping, so that the group center stays at the screen center.
**/
class SplitScreen extends h2d.Drawable {
	public static inline var MAX_VIEWS = 4;

	var scroller : h2d.Object;
	var targets : Array<Entity> = [];
	var targetColors : Array<Col> = [];
	var textures : Array<h3d.mat.Texture> = [];
	var viewOffsetsX : Array<Float> = [];
	var viewOffsetsY : Array<Float> = [];
	var viewScales : Array<Float> = [];
	var viewCam : h2d.Camera;
	var compositeShader : SplitScreenShader;

	/** Split happens when a target leaves this ellipse around the screen center (ratio of the screen half width/height) **/
	public var splitRadiusRatio = 0.85;

	/** 2 targets: once split, each target is moved to this distance from the screen center (ratio of the screen half width/height) **/
	public var dynamicHoldRatio = 0.5;

	/** 2 targets: overshoot of the split ellipse (ratio) over which the targets reach their final position in their half **/
	public var dynamicPlacementRatio = 0.35;

	/** 2 targets: overshoot of the split ellipse (ratio) over which the separator line fades in **/
	public var lineFadeRatio = 0.12;

	/** 2 targets: separator rotation smoothing (0-1, per 60fps frame) **/
	public var rotationSmoothing = 0.12;

	/** 3+ targets: shared screen comes back when every target is inside this ellipse (ratio of the screen half width/height) **/
	public var fixedMergeRatio = 0.7;

	/** 3+ targets: fade duration between shared and split screen, in seconds **/
	public var fixedFadeS = 0.25;

	public var lineColor : Col = White;

	/** 3 targets: margin around the group in the overview quarter (ratio of the quarter size) **/
	public var overviewMargin = 0.15;

	/** 3 targets: inner edges color of the overview quarter **/
	public var overviewEdgeColor : Col = 0x8c8c8c;

	/** Inner edges of the separator, when a target has no specific color **/
	public var borderColor : Col = Black;
	public var borderAlpha = 0.85;

	/** TRUE when the screen is currently (even partially) split **/
	public var isSplit(default,null) = false;

	var smoothedAngle : Null<Float>;
	var fixedSplit = false;
	var fixedFade = 0.;


	public function new(scroller:h2d.Object, ?parent:h2d.Object) {
		super(parent);
		this.scroller = scroller;
		viewCam = new h2d.Camera();
		compositeShader = new SplitScreenShader();
		addShader(compositeShader);
	}


	/** Entities that each get their own view when split (max `MAX_VIEWS`). Optional colors are used for the separator inner edges. **/
	public function setTargets(entities:Array<Entity>, ?colors:Array<Col>) {
		targets = entities.slice(0, MAX_VIEWS);
		targetColors = colors==null ? [] : colors.slice(0, MAX_VIEWS);
	}


	override function onRemove() {
		super.onRemove();
		scroller.visible = true;
		for(t in textures)
			t.dispose();
		textures = [];
	}


	override function sync(ctx:h2d.RenderContext) {
		super.sync(ctx);
		updateViews(ctx.elapsedTime);
	}


	/** Compute views offsets and separators for current frame **/
	function updateViews(elapsedS:Float) {
		var scene = getScene();
		var live = [];
		var liveColors = [];
		for(i in 0...targets.length)
			if( targets[i].isAlive() ) {
				live.push(targets[i]);
				liveColors.push( i<targetColors.length ? targetColors[i] : borderColor );
			}

		if( live.length<2 || scene==null ) {
			resetSplit();
			return;
		}

		// Targets positions on the shared screen, relative to its center
		var screenW = scene.width;
		var screenH = scene.height;
		var relX = [];
		var relY = [];
		var ellipseDists = [];
		var maxEllipseDist = 0.;
		for(e in live) {
			// Use the rendered (interpolated) sprite position, not the physics one: otherwise the target jitters in its own view
			var x = e.sprX*scroller.scaleX + scroller.x - screenW*0.5;
			var y = (e.sprY - e.hei*0.5)*scroller.scaleY + scroller.y - screenH*0.5;
			var dist = ellipseDist(x, y, screenW*0.5*splitRadiusRatio, screenH*0.5*splitRadiusRatio);
			relX.push(x);
			relY.push(y);
			ellipseDists.push(dist);
			maxEllipseDist = M.fmax(maxEllipseDist, dist);
		}

		if( live.length==2 )
			updateDynamicSplit(screenW, screenH, relX, relY, ellipseDists, maxEllipseDist, elapsedS);
		else
			updateFixedSplit(screenW, screenH, relX, relY, maxEllipseDist, elapsedS);

		setShaderCommons(screenW, screenH, live.length, liveColors);
	}


	/** 2 targets: rotating line through the screen center **/
	function updateDynamicSplit(screenW:Float, screenH:Float, relX:Array<Float>, relY:Array<Float>, ellipseDists:Array<Float>, maxEllipseDist:Float, elapsedS:Float) {
		fixedSplit = false;
		fixedFade = 0;

		isSplit = maxEllipseDist>1;
		scroller.visible = !isSplit;
		if( !isSplit ) {
			smoothedAngle = null;
			return;
		}

		// Direction from target 1 to target 0, smoothed
		var rawAngle = Math.atan2(relY[0]-relY[1], relX[0]-relX[1]);
		if( smoothedAngle==null )
			smoothedAngle = rawAngle;
		else {
			var ratio = 1 - Math.pow(1-rotationSmoothing, elapsedS*60);
			smoothedAngle += M.radSubstract(rawAngle, smoothedAngle) * ratio;
		}

		// Targets go progressively from their shared screen position to the middle of their half
		var placement = M.fclamp( (maxEllipseDist-1)/dynamicPlacementRatio, 0, 1 );
		viewOffsetsX = [];
		viewOffsetsY = [];
		viewScales = [1, 1];
		for(i in 0...2) {
			var halfMiddle = smoothedAngle + (i==0 ? 0 : M.PI);
			var ang = Math.atan2(relY[i], relX[i]);
			ang += M.radSubstract(halfMiddle, ang) * placement;

			var keep = ellipseDists[i]>1 ? 1/ellipseDists[i] : 1.;
			var sharedDist = Math.sqrt(relX[i]*relX[i] + relY[i]*relY[i]) * keep;
			var holdDist = ellipseRadius(ang, screenW*0.5*dynamicHoldRatio, screenH*0.5*dynamicHoldRatio);
			var dist = M.lerp(sharedDist, holdDist, placement);

			viewOffsetsX.push( M.round(relX[i] - Math.cos(ang)*dist) );
			viewOffsetsY.push( M.round(relY[i] - Math.sin(ang)*dist) );
		}

		// Half 0 spans [startAngle, startAngle+PI[ and contains target 0 direction
		var s = compositeShader;
		s.mode = 0;
		s.startAngle = smoothedAngle - M.PI*0.5;
		s.lineAlpha = M.fclamp( (maxEllipseDist-1)/lineFadeRatio, 0, 1 );
		s.globalAlpha = 1;
	}


	/** 3+ targets: fixed areas, with hysteresis and fades **/
	function updateFixedSplit(screenW:Float, screenH:Float, relX:Array<Float>, relY:Array<Float>, maxEllipseDist:Float, elapsedS:Float) {
		smoothedAngle = null;

		if( !fixedSplit && maxEllipseDist>1 )
			fixedSplit = true;
		else if( fixedSplit && maxEllipseDist<fixedMergeRatio/splitRadiusRatio )
			fixedSplit = false;

		var fadeStep = fixedFadeS<=0 ? 1 : elapsedS/fixedFadeS;
		fixedFade = M.fclamp( fixedFade + (fixedSplit ? fadeStep : -fadeStep), 0, 1 );

		isSplit = fixedFade>0;
		scroller.visible = fixedFade<1; // shared screen stays visible below the fading split screen
		if( !isSplit )
			return;

		// Each target is centered in its own area
		var count = relX.length;
		viewOffsetsX = [];
		viewOffsetsY = [];
		viewScales = [];
		for(i in 0...count) {
			var area = getFixedArea(i, screenW, screenH);
			var areaCenterX = area.x + area.w*0.5 - screenW*0.5;
			var areaCenterY = area.y + area.h*0.5 - screenH*0.5;
			viewOffsetsX.push( M.round(relX[i] - areaCenterX) );
			viewOffsetsY.push( M.round(relY[i] - areaCenterY) );
			viewScales.push(1);
		}

		if( count==3 )
			addOverviewView(screenW, screenH, relX, relY);

		var s = compositeShader;
		s.mode = 1;
		s.lineAlpha = 1;
		s.globalAlpha = fixedFade;
	}


	/**
		3 targets: 4th quarter shows the whole group, zoomed out to fit.
		The zoom keeps an integer game pixel size when possible (pixel perfect).
	**/
	function addOverviewView(screenW:Float, screenH:Float, relX:Array<Float>, relY:Array<Float>) {
		var area = getFixedArea(3, screenW, screenH);

		// Group bounds, on the shared screen (relative to its center)
		var left = relX[0], right = relX[0], top = relY[0], bottom = relY[0];
		for(i in 1...relX.length) {
			left = M.fmin(left, relX[i]);
			right = M.fmax(right, relX[i]);
			top = M.fmin(top, relY[i]);
			bottom = M.fmax(bottom, relY[i]);
		}
		var boundsW = M.fmax(right-left, 1);
		var boundsH = M.fmax(bottom-top, 1);

		// Zoom out to fit the bounds (with margins) in the quarter, never zoom in
		var usableW = area.w * (1-overviewMargin*2);
		var usableH = area.h * (1-overviewMargin*2);
		var zoom = M.fmin( 1, M.fmin(usableW/boundsW, usableH/boundsH) );
		var gamePixel = scroller.scaleX;
		if( gamePixel*zoom>=1 )
			zoom = Math.floor(gamePixel*zoom) / gamePixel;

		// Transform: screenPos' = screenPos*zoom + offset, so that bounds center goes to the quarter center
		var boundsCenterX = (left+right)*0.5 + screenW*0.5;
		var boundsCenterY = (top+bottom)*0.5 + screenH*0.5;
		var areaCenterX = area.x + area.w*0.5;
		var areaCenterY = area.y + area.h*0.5;
		viewScales.push(zoom);
		viewOffsetsX.push( -M.round(areaCenterX - boundsCenterX*zoom) );
		viewOffsetsY.push( -M.round(areaCenterY - boundsCenterY*zoom) );
	}


	/** Fixed screen area (quarter) of a target. With 3 targets, index 3 is the overview. **/
	public static function getFixedArea(index:Int, screenW:Float, screenH:Float) {
		var halfW = screenW*0.5;
		var halfH = screenH*0.5;
		return {
			x: (index%2) * halfW,
			y: Std.int(index/2) * halfH,
			w: halfW,
			h: halfH,
		}
	}


	function setShaderCommons(screenW:Float, screenH:Float, count:Int, colors:Array<Col>) {
		var s = compositeShader;
		var scale = scroller.scaleX;
		s.viewCount = count;
		s.screenSize.set(screenW, screenH);

		// Separator: 1 light game pixel, with an inner edge of 1 game pixel on each side, using the target color
		s.lineHalfWidth = scale*0.5;
		s.borderWidth = scale;
		s.lineColor.setColor(lineColor);
		s.borderAlpha = borderAlpha;
		var edgeColors = [ for(i in 0...MAX_VIEWS) i<colors.length ? colors[i] : ( count==3 && i==3 ? overviewEdgeColor : borderColor ) ];
		s.edgeColor0.setColor(edgeColors[0]);
		s.edgeColor1.setColor(edgeColors[1]);
		s.edgeColor2.setColor(edgeColors[2]);
		s.edgeColor3.setColor(edgeColors[3]);
	}


	function resetSplit() {
		isSplit = false;
		fixedSplit = false;
		fixedFade = 0;
		smoothedAngle = null;
		scroller.visible = true;
	}


	/** Distance of a point to the center, as a ratio of the ellipse radius in its direction **/
	static inline function ellipseDist(x:Float, y:Float, radiusX:Float, radiusY:Float) {
		return Math.sqrt( (x/radiusX)*(x/radiusX) + (y/radiusY)*(y/radiusY) );
	}


	/** Radius of an ellipse in given direction **/
	static inline function ellipseRadius(ang:Float, radiusX:Float, radiusY:Float) {
		return 1 / ellipseDist(Math.cos(ang), Math.sin(ang), radiusX, radiusY);
	}


	function initTextures(count:Int, wid:Int, hei:Int) {
		if( textures.length==count && textures[0].width==wid && textures[0].height==hei )
			return;

		for(t in textures)
			t.dispose();
		textures = [];
		for(i in 0...count) {
			var t = new h3d.mat.Texture(wid, hei, [Target]);
			t.filter = Nearest;
			textures.push(t);
		}
	}


	@:access(h2d.Object)
	@:access(h2d.Camera)
	function renderViews(ctx:h2d.RenderContext) {
		var scene = getScene();
		initTextures(viewOffsetsX.length, scene.width, scene.height);

		var wasVisible = scroller.visible;
		scroller.visible = true;
		for(i in 0...textures.length) {
			ctx.pushTarget(textures[i]);
			ctx.engine.clear(ctx.engine.backgroundColor==null ? 0x0 : ctx.engine.backgroundColor, 1);

			// Transform the whole scroller rendering: scale (overview only) then offset
			var zoom = i<viewScales.length ? viewScales[i] : 1.;
			viewCam.matA = zoom;
			viewCam.matB = 0;
			viewCam.matC = 0;
			viewCam.matD = zoom;
			viewCam.absX = -viewOffsetsX[i];
			viewCam.absY = -viewOffsetsY[i];
			ctx.pushCamera(viewCam);
			scroller.drawRec(ctx);
			ctx.popCamera();

			ctx.popTarget();
		}
		scroller.visible = wasVisible;
	}


	override function draw(ctx:h2d.RenderContext) {
		if( !isSplit )
			return;

		renderViews(ctx);

		var s = compositeShader;
		s.view1 = textures[ M.imin(1, textures.length-1) ];
		s.view2 = textures[ M.imin(2, textures.length-1) ];
		s.view3 = textures[ M.imin(3, textures.length-1) ];
		emitTile(ctx, h2d.Tile.fromTexture(textures[0]));
	}
}



/** Composes split-screen views and draws separators **/
private class SplitScreenShader extends hxsl.Shader {
	static var SRC = {
		@:import h3d.shader.Base2d;

		@param var view1 : Sampler2D;
		@param var view2 : Sampler2D;
		@param var view3 : Sampler2D;

		/** 0 = dynamic line (2 views), 1 = fixed areas (3-4 views) **/
		@param var mode : Int;
		@param var viewCount : Int;
		@param var screenSize : Vec2;
		@param var startAngle : Float;
		@param var globalAlpha : Float;

		@param var lineAlpha : Float;
		@param var lineHalfWidth : Float;
		@param var borderWidth : Float;
		@param var lineColor : Vec3;
		@param var borderAlpha : Float;
		@param var edgeColor0 : Vec3;
		@param var edgeColor1 : Vec3;
		@param var edgeColor2 : Vec3;
		@param var edgeColor3 : Vec3;

		function fragment() {
			var p = calculatedUV * screenSize;
			var half = screenSize * 0.5;
			var view = 0.;
			var dist = 0.;

			if( mode==0 ) {
				// Line through the screen center
				var d = p - half;
				var normal = vec2( cos(startAngle+1.57079632679), sin(startAngle+1.57079632679) );
				var side = dot(d, normal);
				if( side<0 ) view = 1.;
				dist = abs(side);
			}
			else {
				// Fixed areas
				var right = p.x>=half.x;
				var bottom = p.y>=half.y;
				// Fixed quarters (with 3 targets, the 4th is the overview)
				if( right ) view += 1.;
				if( bottom ) view += 2.;
				dist = min( abs(p.y-half.y), abs(p.x-half.x) );
			}

			var col = textureColor;
			var edge = edgeColor0;
			if( view>0.5 && view<1.5 ) { col = view1.get(calculatedUV); edge = edgeColor1; }
			if( view>1.5 && view<2.5 ) { col = view2.get(calculatedUV); edge = edgeColor2; }
			if( view>2.5 ) { col = view3.get(calculatedUV); edge = edgeColor3; }

			// Separator: light center line, inner edges with the color of the target displayed on this side
			if( dist<lineHalfWidth )
				col.rgb = mix(col.rgb, lineColor, lineAlpha);
			else if( dist<lineHalfWidth+borderWidth )
				col.rgb = mix(col.rgb, edge, borderAlpha*lineAlpha);

			pixelColor = vec4(col.rgb, globalAlpha);
		}
	};
}
