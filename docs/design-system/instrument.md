# Baseline — Instrument Design System

The chosen art direction for Baseline's UI: a **recovery instrument, not a dashboard.**
Source of truth lives in Figma (file `CCVlatyKW7MSHRGE3PK50i`, Page 1, frame
**"BASELINE — INSTRUMENT DS"**) as real color / text / effect **styles** and a
**component** set (`DS/*`). This doc mirrors it for humans and for generating new
screens via the Figma MCP (`use_figma`).

## Principles
- **Mono numerals for data; Inter for sentences.** Numbers read like an instrument.
- **Hairlines and outlines over heavy fills.** Cards are outlined, not blobs.
- **Color only where it carries meaning** — recovery zones, the green "go", violet only for the action.
- **Signature motif:** *you, measured against your 7-day baseline.* The baseline meter (and the
  micro-bars under each metric) repeat this everywhere.
- **Depth from light** — subtle ambient glow + a glow on the active indicator/CTA. Never heavy.

## Tokens

### Color (semantic) — Figma paint styles
| Style | Hex | Use |
|---|---|---|
| Surface/Base | `#0C0A10` | screen background |
| Surface/Raised | `#1C1822` | raised fills (rare; prefer outlines) |
| Surface/Amethyst | `#33203E` | feature surface / avatars / ambient glow |
| Accent/Violet | `#9B6DFF` | interactive only (CTA, links) — never a recovery state |
| Text/Primary | `#F3F0F8` | values, headlines |
| Text/Secondary | `#9B94A8` | supporting copy |
| Text/Faint | `#6A6478` | labels, captions, ticks |
| Stroke/Hairline | `#272231` | rules, outlines, ticks |
| Recovery/Green | `#34D27B` | recovered / cleared / "go" |
| Recovery/Blue | `#4C8DFF` | low-intensity band |
| Recovery/Amber | `#F5A623` | caution band |
| Recovery/Red | `#FF5247` | recover / red day |

### Type — Figma text styles (Roboto Mono for data, Inter for prose)
| Style | Font | Size | Tracking |
|---|---|---|---|
| Number/Hero | Roboto Mono Bold | 104 | -3 |
| Number/Medium | Roboto Mono Bold | 52 | -1 |
| Value/Metric | Roboto Mono Bold | 22 | -0.5 |
| Label/Caps | Roboto Mono Medium | 11 | 2 |
| Meta/Mono | Roboto Mono Regular | 11 | 1 |
| Button/Mono | Roboto Mono Bold | 15 | 1 |
| Tag/Mono | Roboto Mono Medium | 10 | 1.5 |
| Body/Default | Inter Medium | 15 | (lh 22) |
| Body/Small | Inter Regular | 13 | — |
| Headline/Coach | Inter Bold | 28 | -0.5 |

### Effects — Figma effect styles
- **Glow/Accent** — drop shadow `#9B6DFF` α0.45, radius 24, spread -4 (CTA).
- **Glow/State** — drop shadow `#34D27B` α0.6, radius 10 (active indicator).
- **Ambient/Blur** — layer blur 90 (background mood blob, used sparingly).

### Layout
- Screen 393×852. Side margins **24**. Card/button radius **10**. Pill radius **28**.
- Hairlines 1px `Stroke/Hairline`. Section dividers are full-width hairlines.

## Components (`DS/*` in Figma)
- **Recovery Display** — `82 /100` mono + state tag + "▲ x% vs your baseline".
- **Baseline Meter** — horizontal 0–100 scale; red/amber/green zone bars; tick marks;
  shaded **7-day baseline band**; glowing **TODAY** needle. The signature element.
- **Stat Readout** — caps label + mono value + unit + micro baseline-band bar with dot.
- **Dose Scale** — MED / HPL / MDV stepped bar, filled to the cleared level.
- **Prescription Card** — outlined spec sheet: header + session + dose + footer ("WHY →").
- **Button / Primary** — accent fill, mono label, accent glow.
- **Tab Bar** — hairline top, 4 mono caps labels, accent tick on active.
- **Tag** — small pill (state-colored), mono caps.
- **Hairline** — 1px rule.

## Generation kit (Figma MCP `use_figma`)

Gotchas learned (see also memory `figma-mcp-gotchas`):
- **Frame children use coordinates relative to the frame** — set child x/y *after* `appendChild`,
  in 0-based local space. (Sections use absolute coords; frames/components use relative.)
- `use_figma` returns no output — read back with `get_metadata` (grep the saved file) or `get_screenshot`.
- **Build on Page 1 (`0:1`)**, not new pages — the MCP's page list goes stale and you can't find them.

```js
// ---- tokens + helpers ----
function rgb(h){const n=parseInt(h.slice(1),16);return {r:((n>>16)&255)/255,g:((n>>8)&255)/255,b:(n&255)/255};}
function solid(h,o){return [{type:'SOLID',color:rgb(h),opacity:o==null?1:o}];}
function glow(h,r,a,sp){const c=rgb(h);return {type:'DROP_SHADOW',color:{r:c.r,g:c.g,b:c.b,a:a},offset:{x:0,y:0},radius:r,spread:sp||0,visible:true,blendMode:'NORMAL'};}
const C={base:'#0C0A10',surface:'#1C1822',amethyst:'#33203E',accent:'#9B6DFF',hi:'#F3F0F8',
  mid:'#9B94A8',faint:'#6A6478',line:'#272231',green:'#34D27B',blue:'#4C8DFF',amber:'#F5A623',red:'#FF5247'};

async function fonts(){ for(const s of ['Regular','Medium','Semi Bold','Bold']) await figma.loadFontAsync({family:'Inter',style:s});
  let M='Roboto Mono'; try{ for(const s of ['Regular','Medium','Bold']) await figma.loadFontAsync({family:M,style:s}); }catch(e){ M='Inter'; } return M; }

// P = parent frame/component. Append THEN set local x/y.
function T(P,chars,x,y,size,fam,style,hex,opt){opt=opt||{};const t=figma.createText();t.fontName={family:fam,style};
  t.characters=chars;t.fontSize=size;t.fills=solid(hex,opt.o);if(opt.tr!=null)t.letterSpacing={value:opt.tr,unit:'PIXELS'};
  if(opt.lh)t.lineHeight={value:opt.lh,unit:'PIXELS'};
  if(opt.w){t.textAutoResize='HEIGHT';t.resize(opt.w,size);t.textAlignHorizontal=opt.align||'LEFT';}
  P.appendChild(t);t.x=x;t.y=y;return t;}
function RR(P,x,y,w,h,hex,rad,o){const r=figma.createRectangle();r.resize(w,Math.max(1,h));r.fills=solid(hex,o);
  if(rad)r.cornerRadius=rad;P.appendChild(r);r.x=x;r.y=y;return r;}
function ELL(P,x,y,d,hex,o){const e=figma.createEllipse();e.resize(d,d);e.fills=solid(hex,o);P.appendChild(e);e.x=x;e.y=y;return e;}
function frame(name,x,y){const F=figma.createFrame();F.name=name;F.resize(393,852);F.fills=solid(C.base);
  F.clipsContent=true;F.x=x;F.y=y;return F;}

// ---- signature: baseline meter (score 0-100, baseline band lo..hi) ----
function baselineMeter(P, ox, oy, score, lo, hi, M){
  const W=345, vx=v=>ox+(v/100)*W;
  T(P,'TODAY',vx(score)-30,oy,9,M,'Medium',C.green,{w:60,align:'CENTER'});
  const dot=ELL(P,vx(score)-4,oy+14,8,C.green); dot.effects=[glow(C.green,10,0.7,0)];
  RR(P,vx(score)-1,oy+20,2,30,C.green,0);
  const band=RR(P,vx(lo),oy+24,vx(hi)-vx(lo),24,C.hi,2,0.08); band.strokes=solid(C.faint,0.5); band.strokeWeight=1;
  RR(P,vx(0),oy+52,vx(60)-vx(0),3,C.red,0,0.4);
  RR(P,vx(60),oy+52,vx(80)-vx(60),3,C.amber,0,0.45);
  RR(P,vx(80),oy+52,vx(100)-vx(80),3,C.green,0,0.5);
  [0,20,40,60,80,100].forEach(v=>RR(P,vx(v)-0.5,oy+58,1,6,C.line));
}
// buttonPrimary, prescriptionCard, statReadout, doseScale, tabBar follow the same patterns;
// see the DS/* components in Figma for exact specs.
```

When generating a new screen: `const M = await fonts();` then `const F = frame('Name', x, y);`
(place on Page 1, e.g. y=-1100 row), build with the helpers, then read the frame id from
`get_metadata 0:1` and `get_screenshot` it.
