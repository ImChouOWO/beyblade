// Auto-generated from the uploaded Kotlin GLSL sources.
// Shader text is preserved verbatim except for Swift multiline-string indentation.
enum GLEffectShaders {
    enum Blade {
        static let bladeVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aCenterDist;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
                vCenterDist = aCenterDist;
            }
            """

        static let bladeFrag = """
            precision mediump float;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                float d    = abs(vCenterDist);
                float body = 1.0 - smoothstep(0.65, 1.0, d);
                float core = exp(-d * d * 26.0);
                float w    = body * 0.90 + core * 0.55;
                vec3  col  = (vColor.rgb * body * 0.90
                            + vec3(1.0) * core * 0.55) / max(w, 0.001);
                gl_FragColor = vec4(col, vColor.a * min(w, 1.0));
            }
            """

    }

    enum CrimsonLotus {
        static let fireVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aCenterDist;
            attribute float aTrailDist;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
                vCenterDist = aCenterDist;
                vTrailDist = aTrailDist;
            }
            """

        static let fireFrag = """
            precision highp float;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            uniform float uTime;
            
            float hash(vec2 p) {
                return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
            }
            float noise(vec2 p) {
                vec2 i = floor(p);
                vec2 f = fract(p);
                f = f * f * (3.0 - 2.0 * f);
                return mix(mix(hash(i),                  hash(i + vec2(1.0, 0.0)), f.x),
                           mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
            }
            
            void main() {
                float d    = abs(vCenterDist);
                float life = vColor.a;
                float tail = 1.0 - life;                 // 越靠尾部越大
            
                // 火紋向後捲動 → 火舌舔動感
                vec2  uv   = vec2(vTrailDist * 16.0 - uTime * 8.0, vCenterDist * 1.6);
                float n1   = noise(uv);
                float n2   = noise(uv * 2.6 + 7.3);
                float turb = n1 * 0.6 + n2 * 0.4;
            
                // 邊緣撕成火苗 — 撕裂幅度往尾部加劇（尾巴狂舞）
                float cut  = 0.62 + (turb - 0.5) * (0.55 + 0.55 * tail);
                float body = 1.0 - smoothstep(cut - 0.25, cut + 0.08, d);
            
                // 尾部「燒蝕」：雜訊把尾巴咬成一束束分離的火舌，
                // 被咬掉的邊緣留下暗紅餘燼，不是平淡變透明
                float burn = smoothstep(life * 1.15, life * 1.15 + 0.22, n1);
                body *= 1.0 - burn * 0.85;
                if (body <= 0.004) discard;
            
                // 熱度：中心最熱，由湍流與存活度調制
                float heat = (1.0 - d * d) * (0.60 + 0.55 * turb) * (0.30 + 0.70 * life);
            
                // 熱度梯度（基底 = 陀螺色）：深色邊緣 → 飽和本體 → 白熱核心
                vec3 base = vColor.rgb;
                vec3 col  = mix(base * 0.40, base, smoothstep(0.18, 0.58, heat));
                col       = mix(col, mix(base, vec3(1.0), 0.72),
                                smoothstep(0.66, 0.93, heat));
                // 燒蝕邊界泛飽和餘燼光
                col       = mix(col, base, burn * 0.6);
            
                // 基礎不透明度提高，火舌更搶眼
                float a = body * (0.40 + 0.60 * life) * (0.70 + 0.30 * turb);
                gl_FragColor = vec4(col, min(a, 1.0));
            }
            """

        static let polyVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aCenterDist;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
                vCenterDist = aCenterDist;
            }
            """

        static let polyFrag = """
            precision mediump float;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                float d = abs(vCenterDist);
                vec3 hot = mix(vColor.rgb, vec3(1.0), 0.70);
                vec3 col = mix(hot, vColor.rgb, smoothstep(0.12, 0.72, d));
                float a  = vColor.a * (1.0 - smoothstep(0.55, 1.0, d));
                gl_FragColor = vec4(col, a);
            }
            """

        static let hazeVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aSize;
            varying vec4 vColor;
            void main() {
                gl_Position  = vec4(aPosition, 0.0, 1.0);
                gl_PointSize = aSize;
                vColor = aColor;
            }
            """

        static let hazeFrag = """
            precision mediump float;
            varying vec4 vColor;
            void main() {
                vec2  coord = gl_PointCoord - vec2(0.5);
                float r2 = dot(coord, coord) * 4.0;
                if (r2 > 1.0) discard;
                float a = vColor.a * exp(-r2 * 2.5);
                gl_FragColor = vec4(vColor.rgb, a);
            }
            """

    }

    enum DeathRay {
        static let beamVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aCenterDist;
            attribute float aTrailDist;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
                vCenterDist = aCenterDist;
                vTrailDist = aTrailDist;
            }
            """

        static let beamFrag = """
            precision highp float;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            uniform float uTime;
            uniform vec3  uTint;
            
            float hash(vec2 p) {
                return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
            }
            float noise(vec2 p) {
                vec2 i = floor(p);
                vec2 f = fract(p);
                f = f * f * (3.0 - 2.0 * f);
                return mix(mix(hash(i),                  hash(i + vec2(1.0, 0.0)), f.x),
                           mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
            }
            
            void main() {
                float d    = abs(vCenterDist);
                float life = vColor.a;
                float tail = 1.0 - life;
            
                // 沿光柱捲動的雜訊 → 尾端啃蝕
                vec2  uv = vec2(vTrailDist * 22.0 - uTime * 3.0, vCenterDist * 3.0);
                float n1 = noise(uv);
                float n2 = noise(uv * 2.3 + 5.1);
                float nz = n1 * 0.6 + n2 * 0.4;
            
                // 實心白芯 + 過載光暈
                float core = 1.0 - smoothstep(0.18, 0.46, d);
                float glow = exp(-d * d * 6.0);
            
                // 尾端「燒盡」：雜訊把尾巴咬成一束束空洞（越靠尾洞越大）
                float burn = smoothstep(life * 1.05, life * 1.05 + 0.20, nz);
                // 破洞邊緣的燃燒餘光鋸齒殘邊
                float rim  = (1.0 - smoothstep(0.0, 0.10, abs(nz - life * 1.05))) * tail;
            
                float body = (core * 1.0 + glow * 0.55) * (1.0 - burn);
                body += rim * (0.5 + 0.5 * tail);
                if (body <= 0.004) discard;
            
                // 白芯 → 電光藍白光暈
                vec3 col = mix(uTint, vec3(1.0), core);
                col = mix(col, vec3(1.0), rim * 0.7);
            
                float inten = body * (0.55 + 0.45 * life);
                gl_FragColor = vec4(col, min(inten, 1.0));
            }
            """

        static let pointVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aSize;
            varying vec4 vColor;
            void main() {
                gl_Position  = vec4(aPosition, 0.0, 1.0);
                gl_PointSize = aSize;
                vColor = aColor;
            }
            """

        static let pointFrag = """
            precision mediump float;
            varying vec4 vColor;
            void main() {
                vec2  coord = gl_PointCoord - vec2(0.5);
                float r2 = dot(coord, coord) * 4.0;
                if (r2 > 1.0) discard;
                float a = vColor.a * exp(-r2 * 2.2);
                gl_FragColor = vec4(vColor.rgb, a);
            }
            """

        static let lineVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            varying vec4 vColor;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
            }
            """

        static let lineFrag = """
            precision mediump float;
            varying vec4 vColor;
            void main() {
                gl_FragColor = vColor;
            }
            """

    }

    enum Emerald {
        static let vineVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aCenterDist;
            attribute float aTrailDist;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
                vCenterDist = aCenterDist;
                vTrailDist = aTrailDist;
            }
            """

        static let vineFrag = """
            precision highp float;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            uniform float uTime;
            
            float hash(vec2 p) {
                return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
            }
            float noise(vec2 p) {
                vec2 i = floor(p);
                vec2 f = fract(p);
                f = f * f * (3.0 - 2.0 * f);
                return mix(mix(hash(i),                  hash(i + vec2(1.0, 0.0)), f.x),
                           mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
            }
            
            void main() {
                float d    = abs(vCenterDist);
                float life = vColor.a;
                float tail = 1.0 - life;
            
                // 葉緣鋸齒：高頻雜訊撕邊
                float n  = noise(vec2(vTrailDist * 40.0, vCenterDist * 3.0));
                float cut = 0.80 + (n - 0.5) * 0.55;
                float body = 1.0 - smoothstep(cut - 0.12, cut + 0.04, d);
            
                // 尾端漸枯：雜訊把尾巴啃出缺口
                float wither = smoothstep(life * 1.1, life * 1.1 + 0.22, n);
                body *= 1.0 - wither * 0.7;
                if (body <= 0.004) discard;
            
                // 中肋亮線（葉脈），本體 = 陀螺色，邊緣壓深
                float vein = 1.0 - smoothstep(0.0, 0.22, d);
                vec3 col = mix(vColor.rgb * 0.55, vColor.rgb, smoothstep(0.0, 0.6, 1.0 - d));
                col = mix(col, vec3(1.0), vein * 0.40);
            
                float a = body * (0.45 + 0.55 * life);
                gl_FragColor = vec4(col, min(a, 1.0));
            }
            """

        static let leafVert = """
            attribute vec2 aPosition;
            attribute vec2 aUV;
            attribute vec4 aColor;
            varying vec2 vUV;
            varying vec4 vColor;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vUV = aUV;
                vColor = aColor;
            }
            """

        static let leafFrag = """
            precision mediump float;
            varying vec2 vUV;
            varying vec4 vColor;
            void main() {
                float u = vUV.x;
                float v = vUV.y;
                // 兩頭收縮的半寬輪廓（pow>1 → 更尖的針狀）
                float prof = pow(max(0.0, 1.0 - u * u), 0.65);
                float d = abs(v) / max(prof, 0.001);
                if (d > 1.0) discard;
                float edge = 1.0 - smoothstep(0.72, 1.0, d);
                // 中肋亮線（葉脈 / 刃口反光）
                float vein = 1.0 - smoothstep(0.0, 0.16, abs(v));
                vec3 col = mix(vColor.rgb, vec3(1.0), vein * 0.6);
                gl_FragColor = vec4(col, vColor.a * edge);
            }
            """

        static let ringVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            varying vec4 vColor;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
            }
            """

        static let ringFrag = """
            precision mediump float;
            varying vec4 vColor;
            void main() {
                gl_FragColor = vColor;
            }
            """

    }

    enum Generic {
        static let trailVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            varying vec4 vColor;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
            }
            """

        static let trailFrag = """
            precision mediump float;
            varying vec4 vColor;
            void main() {
                gl_FragColor = vColor;
            }
            """

    }

    enum IceShatter {
        static let iceVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aCenterDist;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
                vCenterDist = aCenterDist;
            }
            """

        static let iceFrag = """
            precision mediump float;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                float d     = abs(vCenterDist);
                float sheet = (1.0 - smoothstep(0.72, 1.00, d)) * 0.55;
                float rim   = smoothstep(0.55, 0.80, d) * (1.0 - smoothstep(0.90, 1.00, d)) * 0.85;
                float core  = exp(-d * d * 20.0) * 0.90;
                float w     = sheet + rim + core;
                vec3  col   = (vColor.rgb * sheet
                             + mix(vColor.rgb, vec3(1.0), 0.55) * rim
                             + mix(vColor.rgb, vec3(1.0), 0.90) * core) / max(w, 0.001);
                gl_FragColor = vec4(col, vColor.a * min(w, 1.0));
            }
            """

        static let bladeVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aCenterDist;
            attribute float aTrailDist;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
                vCenterDist = aCenterDist;
                vTrailDist = aTrailDist;
            }
            """

        static let bladeFrag = """
            precision highp float;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            uniform float uTime;
            void main() {
                float d    = abs(vCenterDist);
                float life = vColor.a;
            
                // 刃口：細而銳的白藍切線
                float core = exp(-d * d * 26.0);
                // 刀身：平滑冰面，邊緣俐落收掉
                float body = 1.0 - smoothstep(0.55, 1.0, d);
                // 刃緣高光（兩側反光細線）
                float edge = smoothstep(0.78, 0.93, d) * (1.0 - smoothstep(0.93, 1.0, d));
                // 滑過鏡面流光：沿刀身流動的亮帶（冰刀反光在滑動）
                float sweep = sin(vTrailDist * 26.0 - uTime * 7.0);
                float gloss = smoothstep(0.55, 1.0, sweep) * body * (0.4 + 0.6 * life);
            
                float w = body * 0.5 + core * 0.95 + edge * 0.6 + gloss * 0.55;
                if (w <= 0.004) discard;
            
                vec3 base = vColor.rgb;
                vec3 col  = base * (body * 0.5)
                          + mix(base, vec3(1.0), 0.92) * core
                          + mix(base, vec3(1.0), 0.70) * edge
                          + vec3(1.0) * gloss * 0.55;
                col /= max(w, 0.001);
            
                float a = w * (0.25 + 0.75 * life);
                gl_FragColor = vec4(col, min(a, 1.0));
            }
            """

        static let fogVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aSize;
            varying vec4 vColor;
            void main() {
                gl_Position  = vec4(aPosition, 0.0, 1.0);
                gl_PointSize = aSize;
                vColor = aColor;
            }
            """

        static let fogFrag = """
            precision mediump float;
            varying vec4 vColor;
            void main() {
                vec2  coord = gl_PointCoord - vec2(0.5);
                float r2 = dot(coord, coord) * 4.0;
                if (r2 > 1.0) discard;
                float a = vColor.a * exp(-r2 * 2.4);
                gl_FragColor = vec4(vColor.rgb, a);
            }
            """

    }

    enum InkWash {
        static let inkVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aCenterDist;
            attribute float aTrailDist;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
                vCenterDist = aCenterDist;
                vTrailDist = aTrailDist;
            }
            """

        static let inkFrag = """
            precision highp float;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            uniform float uTime;
            uniform float uStrandAlpha;
            
            float hash(vec2 p) {
                return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
            }
            float noise(vec2 p) {
                vec2 i = floor(p);
                vec2 f = fract(p);
                f = f * f * (3.0 - 2.0 * f);
                return mix(mix(hash(i),                  hash(i + vec2(1.0, 0.0)), f.x),
                           mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
            }
            
            void main() {
                float d    = abs(vCenterDist);
                float life = vColor.a;
                float tail = 1.0 - life;
            
                // 濃淡層次：核心濃（density=1）→ 兩側淡（density=0）
                float density = 1.0 - smoothstep(0.0, 1.0, d);
            
                // 焦墨核心（壓暗陀螺色）→ 微濕行墨邊緣（原陀螺色、半透明）
                vec3 jiao = vColor.rgb * 0.42;
                vec3 col  = mix(vColor.rgb, jiao, smoothstep(0.25, 0.95, density));
            
                // 飛白：沿筆觸方向的條狀噪點 → 不規則白色空隙（速度感、往中後段加劇）
                float fb  = noise(vec2(vTrailDist * 70.0, vCenterDist * 7.0)) * 0.6
                          + noise(vec2(vTrailDist * 24.0, vCenterDist * 3.0)) * 0.4;
                float fbAmt = 0.22 + smoothstep(0.0, 0.6, tail) * 0.55;
                float feibai = 1.0 - smoothstep(1.0 - fbAmt, 1.0, fb);
            
                // 毛筆開叉：低頻噪點把中後段墨帶縱向撕成幾束
                float fork = smoothstep(0.40, 0.62, noise(vec2(vTrailDist * 6.0, vCenterDist * 1.6)));
                float forkCut = 1.0 - fork * smoothstep(0.2, 0.85, tail) * 0.7;
            
                // 收尾 Dissolve：尾端噪點侵蝕、微粒化蒸發（陡峭 → 俐落留白）
                float dis = smoothstep(life * 1.08, life * 1.08 + 0.10, fb);
            
                float body = density * (0.35 + 0.65 * density);
                body *= feibai * forkCut * (1.0 - dis);
                if (body <= 0.004) discard;
            
                float a = body * (0.55 + 0.45 * life) * uStrandAlpha;
                gl_FragColor = vec4(col, min(a, 1.0));
            }
            """

        static let dropVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aSize;
            attribute float aDissolve;
            varying vec4 vColor;
            varying float vDissolve;
            void main() {
                gl_Position  = vec4(aPosition, 0.0, 1.0);
                gl_PointSize = aSize;
                vColor = aColor;
                vDissolve = aDissolve;
            }
            """

        static let dropFrag = """
            precision mediump float;
            varying vec4 vColor;
            varying float vDissolve;
            float hash(vec2 p) {
                return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
            }
            float noise(vec2 p) {
                vec2 i = floor(p);
                vec2 f = fract(p);
                f = f * f * (3.0 - 2.0 * f);
                return mix(mix(hash(i),                  hash(i + vec2(1.0, 0.0)), f.x),
                           mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
            }
            void main() {
                vec2 c = gl_PointCoord - vec2(0.5);
                float r2 = dot(c, c) * 4.0;
                if (r2 > 1.0) discard;
                float base = exp(-r2 * 2.0);
                // 微粒化：噪點侵蝕，dissolve 越高破得越碎（煙散）
                float n = noise(gl_PointCoord * 9.0);
                if (n < vDissolve) discard;
                float a = vColor.a * base;
                if (a < 0.02) discard;
                gl_FragColor = vec4(vColor.rgb, a);
            }
            """

    }

    enum Money {
        static let goldVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aCenterDist;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
                vCenterDist = aCenterDist;
            }
            """

        static let goldFrag = """
            precision mediump float;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                float d    = abs(vCenterDist);
                float body = (1.0 - smoothstep(0.55, 1.0, d)) * 0.55;
                float core = exp(-d * d * 18.0);
                float w    = body + core;
                vec3  col  = (vColor.rgb * body
                            + mix(vColor.rgb, vec3(1.0), 0.75) * core) / max(w, 0.001);
                gl_FragColor = vec4(col, vColor.a * min(w, 1.0));
            }
            """

        static let coinVert = """
            attribute vec2 aPosition;
            attribute vec2 aUV;
            attribute vec4 aColor;
            varying vec2 vUV;
            varying vec4 vColor;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vUV = aUV;
                vColor = aColor;
            }
            """

        static let coinFrag = """
            precision mediump float;
            varying vec2 vUV;
            varying vec4 vColor;
            void main() {
                float r = length(vUV);
                if (r > 1.0) discard;
                vec3 gold = vColor.rgb;
                vec3 deep = gold * 0.55;
                // 邊圈漸深
                vec3 col = mix(gold, deep, smoothstep(0.70, 0.95, r));
                // 靠邊一圈刻紋（錢幣感，避開中央 $）
                float ring = 1.0 - smoothstep(0.0, 0.05, abs(r - 0.80));
                col = mix(col, deep, ring * 0.5);
            
                // ── $ 字樣：上下兩段弧組成 S + 中央貫穿直槓，刻印成深色 ──
                const float PI = 3.14159265;
                vec2 g = vUV / 0.42;
                // 上弧（缺口朝右下）
                vec2 pt = g - vec2(0.0, 0.5);
                float dt = abs(length(pt) - 0.5);
                float gt = abs(mod(atan(pt.y, pt.x) - (-0.6) + PI, 2.0 * PI) - PI);
                float topArc = (1.0 - smoothstep(0.11, 0.18, dt)) * step(0.95, gt);
                // 下弧（缺口朝左上）
                vec2 pb = g - vec2(0.0, -0.5);
                float db = abs(length(pb) - 0.5);
                float gb = abs(mod(atan(pb.y, pb.x) - (2.4) + PI, 2.0 * PI) - PI);
                float botArc = (1.0 - smoothstep(0.11, 0.18, db)) * step(0.95, gb);
                // 中央直槓（貫穿 $）
                float bar = (1.0 - smoothstep(0.08, 0.13, abs(g.x)))
                          * (1.0 - smoothstep(1.08, 1.24, abs(g.y)));
                float dollar = clamp(topArc + botArc + bar, 0.0, 1.0);
                col = mix(col, deep * 0.5, dollar);
            
                // 左上高光（金屬反光，$ 處不打光以保清晰）
                float hl = smoothstep(0.62, 0.0, length(vUV - vec2(-0.32, 0.32)));
                col = mix(col, vec3(1.0), hl * 0.5 * (1.0 - dollar));
                float a = vColor.a * (1.0 - smoothstep(0.94, 1.0, r));
                gl_FragColor = vec4(col, a);
            }
            """

    }

    enum SprayPaint {
        static let paintVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aCenterDist;
            attribute float aTrailDist;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
                vCenterDist = aCenterDist;
                vTrailDist = aTrailDist;
            }
            """

        static let paintFrag = """
            precision highp float;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            uniform float uTime;
            
            float hash(vec2 p) {
                return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
            }
            float noise(vec2 p) {
                vec2 i = floor(p);
                vec2 f = fract(p);
                f = f * f * (3.0 - 2.0 * f);
                return mix(mix(hash(i),                  hash(i + vec2(1.0, 0.0)), f.x),
                           mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
            }
            
            void main() {
                float d    = abs(vCenterDist);
                float life = vColor.a;
                float tail = 1.0 - life;
            
                // 實心漆芯（尾端漸退，只剩噴點）
                float core = (1.0 - smoothstep(0.48, 0.60, d)) * smoothstep(0.05, 0.35, life);
            
                // 噴霧顆粒：邊緣與尾端噪點越多
                float grain = max(noise(vec2(vTrailDist * 60.0, vCenterDist * 34.0)),
                                  noise(vec2(vTrailDist * 130.0 + 3.0, vCenterDist * 72.0)) * 0.85);
                float sprayZone = smoothstep(0.42, 1.05, d) + tail * 0.65;
                float speck = step(sprayZone, grain);              // 硬邊噴點
                float edgeCut = 1.0 - smoothstep(1.0, 1.12, d);
            
                float body = max(core, speck) * edgeCut;
                if (body < 0.5) discard;
            
                // 鮮豔平塗 + 細微顆粒明暗
                vec3 col = vColor.rgb * (0.86 + 0.14 * grain);
                gl_FragColor = vec4(col, 0.96);
            }
            """

        static let splatVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aSize;
            attribute float aSeed;
            varying vec4 vColor;
            varying float vSeed;
            void main() {
                gl_Position  = vec4(aPosition, 0.0, 1.0);
                gl_PointSize = aSize;
                vColor = aColor;
                vSeed = aSeed;
            }
            """

        static let splatFrag = """
            precision mediump float;
            varying vec4 vColor;
            varying float vSeed;
            void main() {
                vec2 c = gl_PointCoord - vec2(0.5);
                float ang = atan(c.y, c.x);
                float rad = length(c) * 2.0;
                float wob = 0.80 + 0.12 * sin(ang * 3.0 + vSeed)
                                 + 0.08 * sin(ang * 5.0 - vSeed * 1.7)
                                 + 0.05 * sin(ang * 8.0 + vSeed * 0.5);
                if (rad > wob) discard;
                float a = vColor.a * (1.0 - smoothstep(wob - 0.12, wob, rad));
                gl_FragColor = vec4(vColor.rgb, a);
            }
            """

    }

    enum Wave {
        static let fluidVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aCenterDist;
            attribute float aTrailDist;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
                vCenterDist = aCenterDist;
                vTrailDist = aTrailDist;
            }
            """

        static let fluidFrag = """
            precision highp float;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            uniform float uTime;
            
            float hash(vec2 p) {
                return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
            }
            float noise(vec2 p) {
                vec2 i = floor(p);
                vec2 f = fract(p);
                f = f * f * (3.0 - 2.0 * f);
                return mix(mix(hash(i),                  hash(i + vec2(1.0, 0.0)), f.x),
                           mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
            }
            
            void main() {
                float d = abs(vCenterDist);
            
                // flow space scrolls backward over time → water rolls forward
                vec2  uv   = vec2(vTrailDist * 14.0 - uTime * 6.0, vCenterDist * 2.2);
                float n1   = noise(uv);                          // broad under-currents
                float n2   = noise(uv * 2.7 + 13.7);             // fine turbulence
                float turb = n1 * 0.65 + n2 * 0.35;
            
                // ragged silhouette — noise tears the edge dynamically
                float edgeCut = 0.74 + (turb - 0.5) * 0.40;
                float body = 1.0 - smoothstep(edgeCut - 0.15, edgeCut + 0.10, d);
                if (body <= 0.004) discard;
            
                // dark currents + ripple shading, hue stays the beyblade's
                vec3 col = vColor.rgb * (0.78 + 0.30 * turb);
                // rolling crest sheen: color lifted 50%, not white
                float crest = smoothstep(0.72, 0.88, n2);
                col = mix(col, vColor.rgb * 0.5 + vec3(0.5), crest * 0.45);
            
                float a = body * (0.45 + 0.50 * vColor.a) * (0.85 + 0.15 * turb);
                gl_FragColor = vec4(col, a);
            }
            """

        static let waveTrailVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aCenterDist;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
                vCenterDist = aCenterDist;
            }
            """

        static let waveTrailFrag = """
            precision mediump float;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                float dist = abs(vCenterDist);
                float glow = 1.0 - dist * dist;
                gl_FragColor = vec4(vColor.rgb, vColor.a * glow);
            }
            """

        static let particleVert = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aSize;
            varying vec4 vColor;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                gl_PointSize = aSize;
                vColor = aColor;
            }
            """

        static let particleFrag = """
            precision mediump float;
            varying vec4 vColor;
            void main() {
                vec2 coord = gl_PointCoord - vec2(0.5);
                float dist = length(coord) * 2.0;
                if (dist > 1.0) discard;
                float alpha = vColor.a * (1.0 - dist * dist);
                gl_FragColor = vec4(vColor.rgb, alpha);
            }
            """

    }

}