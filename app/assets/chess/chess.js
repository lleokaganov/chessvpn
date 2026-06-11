/* Idiotychess engine + board widget.
   Usage:
     <link rel="stylesheet" href="chess.css">
     <script src="chess.js"></script>
     chess.start(elementOrSelector);   // draws status + board + button inside it

   White = the human (bottom), brave: no check rules at all, the white king may
   walk into fire and sit there. Black = the idiot: a STANDARD chess army (so the
   board looks like ordinary chess), but he makes two random moves per turn -- and
   he is a COWARD about his own king (never steps into attack, never left in check,
   must escape check). You win by checkmating OR stalemating him; you lose if the
   idiot randomly blunders onto your brave king. Pawns auto-promote to queen.
   Each chess.start() call is an independent game; call it many times for many
   boards on one page. */
(function (global) {
  "use strict";

  // Solid glyph set; CSS colours by side. U+FE0E (appended in render) forces text
  // presentation so phones don't draw these as colour emoji.
  var GLYPH = {p:"♟",n:"♞",b:"♝",r:"♜",q:"♛",k:"♚"};
  var VS = String.fromCharCode(0xFE0E);

  var START = [
    "rnbqkbnr",
    "pppppppp",
    "........",
    "........",
    "........",
    "........",
    "PPPPPPPP",
    "RNBQKBNR",
  ];
  var IDIOT_MOVES = 2;               // random black moves per turn

  // ---------- pure engine (operate on a passed-in board; no shared state) ----------
  const isWhite = p => p && p === p.toUpperCase();
  const isBlack = p => p && p === p.toLowerCase();
  const sameSide = (a,b) => a && b && (isWhite(a) === isWhite(b));
  const inside = (r,c) => r>=0 && r<8 && c>=0 && c<8;
  const isKing = p => p && p.toLowerCase()==="k";

  function freshBoard(){
    return START.map(row => row.split("").map(ch => ch === "." ? "" : ch));
  }

  // Legal destination squares for the piece at (r,c) by movement only (ignores check).
  function moves(bd, r, c){
    const p = bd[r][c]; if(!p) return [];
    const out = [];
    const me = p.toLowerCase();
    const add = (tr,tc) => {                 // returns true if sliding may continue
      if(!inside(tr,tc)) return false;
      const t = bd[tr][tc];
      if(!t){ out.push([tr,tc]); return true; }
      if(!sameSide(p,t)) out.push([tr,tc]);
      return false;
    };
    const slide = dirs => dirs.forEach(([dr,dc])=>{ let tr=r+dr,tc=c+dc; while(add(tr,tc)){tr+=dr;tc+=dc;} });
    const diag=[[-1,-1],[-1,1],[1,-1],[1,1]], orth=[[-1,0],[1,0],[0,-1],[0,1]];
    if(me==="p"){
      const dir = isWhite(p) ? -1 : 1;       // white goes up the board
      const startRow = isWhite(p) ? 6 : 1;
      if(inside(r+dir,c) && !bd[r+dir][c]){
        out.push([r+dir,c]);
        if(r===startRow && !bd[r+2*dir][c]) out.push([r+2*dir,c]);
      }
      for(const dc of [-1,1]){
        const tr=r+dir, tc=c+dc;
        if(inside(tr,tc) && bd[tr][tc] && !sameSide(p,bd[tr][tc])) out.push([tr,tc]);
      }
    } else if(me==="n"){
      for(const [dr,dc] of [[-2,-1],[-2,1],[-1,-2],[-1,2],[1,-2],[1,2],[2,-1],[2,1]]) add(r+dr,c+dc);
    } else if(me==="b") slide(diag);
    else if(me==="r") slide(orth);
    else if(me==="q") slide(diag.concat(orth));
    else if(me==="k"){ for(const [dr,dc] of diag.concat(orth)) add(r+dr,c+dc); }
    return out;
  }

  // Is square (r,c) of board bd attacked by pieces of the given side?
  function attacked(bd, r, c, byWhite){
    const pr = r + (byWhite ? 1 : -1);       // an attacking pawn sits one row toward its own side
    for(const dc of [-1,1]){
      const t = inside(pr,c+dc) ? bd[pr][c+dc] : "";
      if(t && t.toLowerCase()==="p" && isWhite(t)===byWhite) return true;
    }
    for(const [dr,dc] of [[-2,-1],[-2,1],[-1,-2],[-1,2],[1,-2],[1,2],[2,-1],[2,1]]){
      const t = inside(r+dr,c+dc) ? bd[r+dr][c+dc] : "";
      if(t && t.toLowerCase()==="n" && isWhite(t)===byWhite) return true;
    }
    for(const [dr,dc] of [[-1,-1],[-1,0],[-1,1],[0,-1],[0,1],[1,-1],[1,0],[1,1]]){
      const t = inside(r+dr,c+dc) ? bd[r+dr][c+dc] : "";
      if(t && t.toLowerCase()==="k" && isWhite(t)===byWhite) return true;
    }
    const ray = (dirs, types) => {
      for(const [dr,dc] of dirs){
        let tr=r+dr, tc=c+dc;
        while(inside(tr,tc)){
          const t=bd[tr][tc];
          if(t){ if(isWhite(t)===byWhite && types.includes(t.toLowerCase())) return true; break; }
          tr+=dr; tc+=dc;
        }
      }
      return false;
    };
    if(ray([[-1,-1],[-1,1],[1,-1],[1,1]], ["b","q"])) return true;  // diagonals
    if(ray([[-1,0],[1,0],[0,-1],[0,1]], ["r","q"])) return true;     // files/ranks
    return false;
  }
  function findKing(bd, white){
    const k = white ? "K" : "k";
    for(let r=0;r<8;r++) for(let c=0;c<8;c++) if(bd[r][c]===k) return [r,c];
    return null;
  }
  function inCheck(bd, white){
    const k = findKing(bd, white);
    return !!k && attacked(bd, k[0], k[1], !white);
  }
  // A throwaway copy of bd with the move applied (pawns promote). No side effects.
  function tryMove(bd, fr,fc,tr,tc){
    const nb = bd.map(row => row.slice());
    const p = nb[fr][fc];
    nb[tr][tc]=p; nb[fr][fc]="";
    if(p==="P" && tr===0) nb[tr][tc]="Q";
    if(p==="p" && tr===7) nb[tr][tc]="q";
    return nb;
  }
  // moves() filtered so the mover never leaves its own king in check. Applied to the
  // idiot's black pieces this single filter makes his king a coward. (White never
  // calls it -- brave king, no restrictions.)
  function legalMoves(bd, r, c){
    const p = bd[r][c]; if(!p) return [];
    const white = isWhite(p);
    return moves(bd,r,c).filter(([tr,tc]) => !inCheck(tryMove(bd,r,c,tr,tc), white));
  }

  // ---------- one playable board widget bound to a container ----------
  function start(target){
    const container = typeof target === "string" ? document.querySelector(target) : target;
    if(!container) throw new Error("chess.start: container not found");

    let board, selected, legal, busy, over, last;

    container.classList.add("chess");
    container.innerHTML = "";
    const statusEl = document.createElement("div"); statusEl.className = "chess-status";
    const boardEl  = document.createElement("div"); boardEl.className  = "chess-board";
    const btns     = document.createElement("div"); btns.className     = "chess-btns";
    const newBtn   = document.createElement("button"); newBtn.textContent = "Новая игра";
    btns.appendChild(newBtn);
    container.appendChild(statusEl);
    container.appendChild(boardEl);
    container.appendChild(btns);

    const setStatus = t => { statusEl.textContent = t; };

    function reset(){
      board = freshBoard();
      selected = null; legal = []; busy = false; over = false; last = null;
      setStatus("Ваш ход.");
      render();
    }
    // Apply a move to the live board; promote pawns. Returns the captured piece ('' if none).
    function apply(fr,fc,tr,tc){
      const p = board[fr][fc];
      const captured = board[tr][tc];
      board[tr][tc] = p;
      board[fr][fc] = "";
      if(p==="P" && tr===0) board[tr][tc]="Q";
      if(p==="p" && tr===7) board[tr][tc]="q";
      last = [fr,fc,tr,tc];
      return captured;
    }
    function render(){
      boardEl.innerHTML="";
      for(let r=0;r<8;r++) for(let c=0;c<8;c++){
        const sq=document.createElement("div");
        sq.className="chess-sq "+((r+c)%2?"d":"l");
        if(last && ((r===last[0]&&c===last[1])||(r===last[2]&&c===last[3]))) sq.classList.add("last");
        if(selected && selected[0]===r && selected[1]===c) sq.classList.add("sel");
        if(legal.some(m=>m[0]===r&&m[1]===c)){ sq.classList.add("mv"); if(board[r][c]) sq.classList.add("cap"); }
        const p=board[r][c];
        if(p){ const s=document.createElement("span");
          s.className="chess-pc "+(isWhite(p)?"w":"b"); s.textContent=GLYPH[p.toLowerCase()]+VS; sq.appendChild(s); }
        sq.onclick=()=>onClick(r,c);
        boardEl.appendChild(sq);
      }
    }
    // Covert VPN toggle: the white knight g1<->a3 gesture. Not a legal chess move,
    // so it never happens by accident in a real game and reads as ordinary play to
    // a bystander. g1->a3 arms (connect), a3->g1 disarms (disconnect). The knight
    // visibly sits on a3 while armed. When the host app isn't present (plain web),
    // the bridge is a no-op and it's just a harmless knight teleport.
    function vpnBridge(action){
      try{ if(window.Unlock && window.Unlock.postMessage) window.Unlock.postMessage(action); }catch(e){}
    }
    function secretKnight(fr,fc,tr,tc,action){
      board[tr][tc]=board[fr][fc]; board[fr][fc]=""; last=[fr,fc,tr,tc];
      selected=null; legal=[]; render(); vpnBridge(action);
    }
    function onClick(r,c){
      if(busy||over) return;
      const p=board[r][c];
      if(selected){
        const sp=board[selected[0]][selected[1]];
        if(sp==="N"){
          if(selected[0]===7&&selected[1]===6&&r===5&&c===0) return secretKnight(7,6,5,0,"on");
          if(selected[0]===5&&selected[1]===0&&r===7&&c===6) return secretKnight(5,0,7,6,"off");
        }
        if(legal.some(m=>m[0]===r&&m[1]===c)){ humanMove(selected[0],selected[1],r,c); return; }
        if(isWhite(p)){ selected=[r,c]; legal=moves(board,r,c); render(); return; }
        selected=null; legal=[]; render(); return;
      }
      if(isWhite(p)){ selected=[r,c]; legal=moves(board,r,c); render(); }
    }
    function humanMove(fr,fc,tr,tc){
      const cap=apply(fr,fc,tr,tc);
      selected=null; legal=[]; render();
      if(isKing(cap)){ return endGame(true); }
      busy=true; setStatus("Идиот думает…");
      setTimeout(()=>idiotMove(1), 650);
    }
    function idiotMove(step){
      // collect black pieces with a coward-legal move (one that keeps the black king safe)
      const movers=[];
      for(let r=0;r<8;r++) for(let c=0;c<8;c++)
        if(isBlack(board[r][c])){ const m=legalMoves(board,r,c); if(m.length) movers.push([r,c,m]); }
      if(!movers.length){ return endGame(true); }   // coward has no legal move: mate/stalemate -> you win
      const [fr,fc,m]=movers[(Math.random()*movers.length)|0];
      const [tr,tc]=m[(Math.random()*m.length)|0];
      const cap=apply(fr,fc,tr,tc);
      render();
      if(isKing(cap)){ return endGame(false); }
      if(step < IDIOT_MOVES){
        setStatus("…и ещё раз!");
        setTimeout(()=>idiotMove(step+1), 700);
      } else { setStatus("Ваш ход."); busy=false; }
    }
    function endGame(win){
      over=true; busy=false; selected=null; legal=[];
      setStatus(win ? "Вы победили!" : "Вы проиграли!");
      render();
    }

    newBtn.onclick = reset;
    reset();
    return { reset };               // minimal handle: restart programmatically if needed
  }

  global.chess = { start };
})(typeof window !== "undefined" ? window : this);
