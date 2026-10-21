/**
	Dynamic split-screen for local multiplayer ("DBZ" / Voronoi style).

	- While every target stays close to the group center, all views are identical: a single shared screen is displayed.
	- When targets move apart, the screen is cut in pie slices around the group center: one slice per target, ordered by angle.
	  With 2 targets, the cut is a straight line perpendicular to the direction between them.
	- Each target stays at the edge of an ellipse around the group center, in its own slice, so the transition from shared to split screen is seamless.

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

		// Group center, in level pixels and on screen
		var groupX = 0.;
		var groupY = 0.;
		for(e in live) {
			groupX += e.centerX;
			groupY += e.centerY;
		}
		groupX /= live.length;
		groupY /= live.length;
		var centerX = M.fclamp( groupX*scale + scroller.x, screenW*0.1, screenW*0.9 );
		var centerY = M.fclamp( groupY*scale + scroller.y, screenH*0.1, screenH*0.9 );

		// Each target is kept inside an ellipse around the group center: the view offset is what exceeds it
		var radiusX = screenW*0.5*splitRadiusRatio;
		var radiusY = screenH*0.5*splitRadiusRatio;
		var maxEllipseDist = 0.;
		var angles = [];
		viewOffsetsX = [];
		viewOffsetsY = [];
		for(e in live) {
			var relX = (e.centerX-groupX) * scale;
			var relY = (e.centerY-groupY) * scale;
			var ellipseDist = Math.sqrt( (relX/radiusX)*(relX/radiusX) + (relY/radiusY)*(relY/radiusY) );
			var keep = ellipseDist>1 ? 1/ellipseDist : 1;
			viewOffsetsX.push( M.round(relX - relX*keep) );
			viewOffsetsY.push( M.round(relY - relY*keep) );
			angles.push( Math.atan2(relY, relX) );
			maxEllipseDist = M.fmax(maxEllipseDist, ellipseDist);
		}

		setSplit( maxEllipseDist>1 );
		if( !isSplit )
			return;

		// Pie slices: targets sorted by angle, boundaries at mid-angles between neighbours
		var order = [ for(i in 0...live.length) i ];
		order.sort( (a,b)->Reflect.compare(angles[a], angles[b]) );
		var boundaries = [];
		for(k in 0...order.length) {
			var a = angles[ order[k] ];
			var b = angles[ order[(k+1) % order.length] ];
			var delta = positiveAngle(b-a);
			if( delta<=0 )
				delta = M.PI2; // same angle (only possible with a single distinct direction)
			boundaries.push(a + delta*0.5);
		}

		// Shader params: sector k spans [boundary k, boundary k+1[ and displays target order[k+1]
		var s = compositeShader;
		s.viewCount = live.length;
		s.screenSize.set(screenW, screenH);
		s.center.set(centerX, centerY);
		s.startAngle = boundaries[0];
		var rel = [ for(k in 1...MAX_VIEWS) k<boundaries.length ? positiveAngle(boundaries[k]-boundaries[0]) : 99. ];
		s.bounds.set(rel[0], rel[1], rel[2]);
		var sectorView = [ for(k in 0...MAX_VIEWS) k<order.length ? order[(k+1) % order.length] : 0 ];
		s.sectorViews.set(sectorView[0], sectorView[1], sectorView[2], sectorView[3]);

		// Separator: 1 light game pixel, with a darker game pixel on each side
		s.lineAlpha = M.fclamp( (maxEllipseDist-1)/lineFadeRatio, 0, 1 );
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
