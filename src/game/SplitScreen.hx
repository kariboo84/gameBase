/**
	Dynamic split-screen for local multiplayer ("DBZ" / Voronoi style).

	- While every target stays close to the group center, all views are identical: a single shared screen is displayed.
	- When targets move apart, the screen is cut in EQUAL pie slices meeting at the screen center: one slice per target, ordered by angle,
	  rotated to best match the targets directions. With 2 targets, the cut is a straight line perpendicular to the direction between them.
	- Each target stays on an ellipse around the screen center, progressively moved to the middle of its slice, so the transition from shared to split screen is seamless.
	- For this to work, the main camera should keep the group center at the screen center: disable level bounds clamping while several targets are tracked.

	The game scroller is rendered once per view into an offscreen texture (same pixel-perfect scale), then a shader composes the final image and draws the separator lines.
	The main `Camera` should track the same group (`camera.trackGroup(...)`).
**/
class SplitScreen extends h2d.Drawable {
	public static inline var MAX_VIEWS = 4;

	var scroller : h2d.Object;
	var targets : Array<Entity> = [];
	var textures : Array<h3d.mat.Texture> = [];
	var viewOffsetsX : Array<Float> = [];
	var viewOffsetsY : Array<Float> = [];
	var viewCam : h2d.Camera;
	var compositeShader : SplitScreenShader;

	/** Split starts when a target leaves this ellipse around the group center (ratio of the screen half width/height) **/
	public var splitRadiusRatio = 0.55;

	/** Distance (ratio of the ellipse) over which the separator line fades in **/
	public var lineFadeRatio = 0.12;

	public var lineColor : Col = White;
	public var borderColor : Col = Black;
	public var borderAlpha = 0.5;

	/** TRUE when the screen is currently split **/
	public var isSplit(default,null) = false;


	public function new(scroller:h2d.Object, ?parent:h2d.Object) {
		super(parent);
		this.scroller = scroller;
		viewCam = new h2d.Camera();
		compositeShader = new SplitScreenShader();
		addShader(compositeShader);
	}


	/** Entities that each get their own view when split (max `MAX_VIEWS`) **/
	public function setTargets(entities:Array<Entity>) {
		targets = entities.slice(0, MAX_VIEWS);
	}


	function getLiveTargets() : Array<Entity> {
		return targets.filter( e->e.isAlive() );
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
		updateViews();
	}


	/** Compute views offsets, slices and separator lines for current frame **/
	function updateViews() {
		var live = getLiveTargets();
		var scene = getScene();
		if( live.length<2 || scene==null ) {
			setSplit(false);
			return;
		}

		var screenW = scene.width;
		var screenH = scene.height;
		var scale = scroller.scaleX;
		var count = live.length;

		// Slices always meet at the screen center, so they all get the same area
		var centerX = screenW*0.5;
		var centerY = screenH*0.5;

		// Targets positions on the shared view, relative to screen center
		var radiusX = screenW*0.5*splitRadiusRatio;
		var radiusY = screenH*0.5*splitRadiusRatio;
		var maxEllipseDist = 0.;
		var relX = [];
		var relY = [];
		var ellipseDists = [];
		var angles = [];
		for(e in live) {
			var x = e.centerX*scale + scroller.x - centerX;
			var y = e.centerY*scale + scroller.y - centerY;
			var dist = Math.sqrt( (x/radiusX)*(x/radiusX) + (y/radiusY)*(y/radiusY) );
			relX.push(x);
			relY.push(y);
			ellipseDists.push(dist);
			angles.push( Math.atan2(y,x) );
			maxEllipseDist = M.fmax(maxEllipseDist, dist);
		}

		setSplit( maxEllipseDist>1 );
		if( !isSplit )
			return;

		// Equal slices (360/count each). Only their rotation and their attribution are chosen,
		// to keep the targets order around the center and to best match their directions.
		var sliceAng = M.PI2 / count;
		var order = [ for(i in 0...count) i ];
		order.sort( (a,b)->Reflect.compare(angles[a], angles[b]) );

		var bestShift = 0;
		var bestRotation = 0.;
		var bestError = 1e9;
		for(shift in 0...count) {
			// Optimal rotation for this attribution: circular mean of the angular differences
			var sumCos = 0.;
			var sumSin = 0.;
			for(k in 0...count) {
				var a = angles[ order[(k+shift) % count] ] - (k+0.5)*sliceAng;
				sumCos += Math.cos(a);
				sumSin += Math.sin(a);
			}
			var rotation = Math.atan2(sumSin, sumCos);
			var error = 0.;
			for(k in 0...count) {
				var diff = M.radSubstract( angles[ order[(k+shift) % count] ], rotation + (k+0.5)*sliceAng );
				error += diff*diff;
			}
			if( error<bestError ) {
				bestError = error;
				bestShift = shift;
				bestRotation = rotation;
			}
		}

		// Slice middle angle of each target
		var sliceMiddle = [ for(i in 0...count) 0. ];
		var sectorView = [ for(k in 0...MAX_VIEWS) 0 ];
		for(k in 0...count) {
			var target = order[(k+bestShift) % count];
			sliceMiddle[target] = bestRotation + (k+0.5)*sliceAng;
			sectorView[k] = target;
		}

		// View offsets: each target is kept on its ellipse, progressively moved toward the middle of its slice
		var splitRatio = M.fclamp( (maxEllipseDist-1)/lineFadeRatio, 0, 1 );
		viewOffsetsX = [];
		viewOffsetsY = [];
		for(i in 0...count) {
			var keep = ellipseDists[i]>1 ? 1/ellipseDists[i] : 1.;
			var dist = Math.sqrt(relX[i]*relX[i] + relY[i]*relY[i]) * keep;
			var ang = angles[i] + M.radSubstract(sliceMiddle[i], angles[i]) * splitRatio;
			var wantedX = Math.cos(ang) * dist;
			var wantedY = Math.sin(ang) * dist;
			viewOffsetsX.push( M.round(relX[i] - wantedX) );
			viewOffsetsY.push( M.round(relY[i] - wantedY) );
		}

		// Shader params: slice k starts at rotation + k*sliceAng
		var s = compositeShader;
		s.viewCount = count;
		s.screenSize.set(screenW, screenH);
		s.center.set(centerX, centerY);
		s.startAngle = bestRotation;
		s.bounds.set(sliceAng, sliceAng*2, sliceAng*3);
		s.sectorViews.set(sectorView[0], sectorView[1], sectorView[2], sectorView[3]);

		// Separator: 1 light game pixel, with a darker game pixel on each side
		s.lineAlpha = splitRatio;
		s.lineHalfWidth = scale*0.5;
		s.borderWidth = scale;
		s.lineColor.setColor(lineColor);
		s.borderColor.setColor(borderColor);
		s.borderColor.w = borderAlpha;
	}


	/** Normalize an angle to [0,2PI[ **/
	static function positiveAngle(a:Float) : Float {
		while( a<0 )
			a += M.PI2;
		while( a>=M.PI2 )
			a -= M.PI2;
		return a;
	}


	function setSplit(v:Bool) {
		isSplit = v;
		scroller.visible = !v;
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

		scroller.visible = true;
		for(i in 0...textures.length) {
			ctx.pushTarget(textures[i]);
			ctx.engine.clear(ctx.engine.backgroundColor==null ? 0x0 : ctx.engine.backgroundColor, 1);

			// Translate the whole scroller rendering by the view offset
			viewCam.matA = 1;
			viewCam.matB = 0;
			viewCam.matC = 0;
			viewCam.matD = 1;
			viewCam.absX = -viewOffsetsX[i];
			viewCam.absY = -viewOffsetsY[i];
			ctx.pushCamera(viewCam);
			scroller.drawRec(ctx);
			ctx.popCamera();

			ctx.popTarget();
		}
		scroller.visible = false;
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



/** Composes split-screen views (pie slices) and draws separator lines **/
private class SplitScreenShader extends hxsl.Shader {
	static var SRC = {
		@:import h3d.shader.Base2d;

		@param var view1 : Sampler2D;
		@param var view2 : Sampler2D;
		@param var view3 : Sampler2D;

		@param var viewCount : Int;
		@param var screenSize : Vec2;
		@param var center : Vec2;
		@param var startAngle : Float;
		@param var bounds : Vec3;
		@param var sectorViews : Vec4;

		@param var lineAlpha : Float;
		@param var lineHalfWidth : Float;
		@param var borderWidth : Float;
		@param var lineColor : Vec3;
		@param var borderColor : Vec4;

		/** Distance from point `d` (relative to center) to the half-line starting at center with angle `a` **/
		function rayDist(d:Vec2, a:Float) : Float {
			var u = vec2(cos(a), sin(a));
			var along = dot(d, u);
			var perp = abs(d.x*u.y - d.y*u.x);
			var dist = length(d);
			if( along>0 )
				dist = perp;
			return dist;
		}

		function fragment() {
			var p = calculatedUV * screenSize;
			var d = p - center;
			var twoPi = 6.28318530718;
			var rel = mod( atan(d.y, d.x) - startAngle + twoPi*2, twoPi );

			// Sector (pie slice) of this pixel, and the view it displays
			var view = sectorViews.x;
			if( viewCount>1 && rel>=bounds.x ) view = sectorViews.y;
			if( viewCount>2 && rel>=bounds.y ) view = sectorViews.z;
			if( viewCount>3 && rel>=bounds.z ) view = sectorViews.w;

			var col = textureColor;
			if( view>0.5 && view<1.5 ) col = view1.get(calculatedUV);
			if( view>1.5 && view<2.5 ) col = view2.get(calculatedUV);
			if( view>2.5 ) col = view3.get(calculatedUV);

			// Separator lines
			var dist = rayDist(d, startAngle);
			if( viewCount>1 ) dist = min(dist, rayDist(d, startAngle+bounds.x));
			if( viewCount>2 ) dist = min(dist, rayDist(d, startAngle+bounds.y));
			if( viewCount>3 ) dist = min(dist, rayDist(d, startAngle+bounds.z));

			if( dist<lineHalfWidth )
				col.rgb = mix(col.rgb, lineColor, lineAlpha);
			else if( dist<lineHalfWidth+borderWidth )
				col.rgb = mix(col.rgb, borderColor.rgb, borderColor.a*lineAlpha);

			pixelColor = vec4(col.rgb, 1);
		}
	};
}
