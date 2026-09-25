/*  SGOverlay.ms  (v4.1 : 高速化版 その2)
    ------------------------------------------------------------
    Editable Poly / ポリゴン編集(Edit Poly) のポリゴン・要素レベルで、
    選択中の各ポリゴンの中心に以下をオーバーレイ表示します。

      ・スムージンググループ番号（複数は "1,3" 形式、未割当は "-"）
      ・マテリアルID
      ・両方（上段=SG、下段=MatID）

    v3 の変更点（高ポリゴン対策）
      ・面データ / 画面ポリラインのキャッシュ
      ・画面外 / カメラ背後 / 裏面のスキップ、重なりラベルの間引き
      ・7セグ文字を 1文字 = 1ポリライン で描画
      ・視点ドラッグ中は描画を省略するオプション

    v4 の変更点（大量選択時の視点変更を高速化）
      ・選択面をワールド空間のボクセルでクラスタリングし、
        視点変更時はクラスタ単位で画面外/背後を一括除外。
        画面上で1セルより小さいクラスタは代表面1つで判定するため、
        再構築コストが「選択面数」ではなく「クラスタ数 + 表示ラベル数」に比例
      ・Edit Poly で共有頂点の座標をキャッシュ（GetVertex 呼び出しを約1/4に）
      ・描画方式「テキスト（高速）」を追加：1ラベル = gw.wText 1回
      ・ホットループ内のグローバル参照をローカル化

    ※ Dictionary を使用するため 3ds Max 2017.1 以降が必要です。
    使い方 : Scripting > Run Script で実行
*/

-- ============================================================
-- 前回実行分の後始末（再実行対策）
-- ============================================================
global sgOverlayDraw
global sgOverlayRoll
try (unregisterRedrawViewsCallback sgOverlayDraw) catch()
try (destroyDialog sgOverlayRoll) catch()
deleteAllChangeHandlers id:#sgOverlayWatch

-- ============================================================
-- 設定
-- ============================================================
global sgOverlayActive     = false
global sgOverlayMode       = 1                  -- 1:SG  2:MatID  3:両方
global sgOverlaySize       = 12                 -- 文字の高さ(px)（ベクター時）
global sgOverlayColorSG    = color 255 255 0
global sgOverlayColorID    = color 0 200 255
global sgOverlayCullBack   = true               -- 裏面を表示しない
global sgOverlayThin       = true               -- 重なりを間引く
global sgOverlaySkipNav    = true               -- 視点ドラッグ中は描画しない
global sgOverlayTextMode   = false              -- true: gw.wText で描画
global sgOverlayClusterMin = 1500               -- この選択数以上でクラスタリング

-- ============================================================
-- キャッシュ
-- ============================================================
global sgOverlayNode         = undefined
global sgOverlayOwner        = undefined
global sgOverlayTM           = undefined
global sgOverlayUseTM        = undefined        -- Edit_Poly 座標系判定結果
global sgOverlayDataDirty    = true             -- 面データを破棄すべきか
global sgOverlayClusterDirty = true             -- クラスタを作り直すべきか
global sgOverlayScreenDirty  = true             -- 画面描画データを作り直すべきか

global sgOverlayFDoneGeo  = #{}                 -- 中心・法線 取得済みの面
global sgOverlayFDoneAttr = #{}                 -- SG・MatID 取得済みの面
global sgOverlayFC  = #()                       -- 面中心（ワールド）
global sgOverlayFN  = #()                       -- 面法線（ワールド、非正規化）
global sgOverlayFSG = #()                       -- SG 文字列
global sgOverlayFID = #()                       -- MatID 文字列
global sgOverlayVDone = #{}                     -- Edit Poly 頂点座標 取得済み
global sgOverlayVP    = #()                     -- Edit Poly 頂点座標（ワールド）

global sgOverlayClC   = #()                     -- クラスタ中心
global sgOverlayClR   = #()                     -- クラスタ半径
global sgOverlayClRep = #()                     -- 代表面
global sgOverlayClM   = #()                     -- メンバー面の配列

global sgOverlayPrevSel = #{}
global sgOverlayViewSig = #()
global sgOverlayScrSG   = #()                   -- ベクター：画面ポリライン（SG色）
global sgOverlayScrID   = #()                   -- ベクター：画面ポリライン（MatID色）
global sgOverlayTxPSG   = #()                   -- テキスト：位置（SG）
global sgOverlayTxSSG   = #()                   -- テキスト：文字列（SG）
global sgOverlayTxPID   = #()
global sgOverlayTxSID   = #()

global sgOverlaySGStr    = Dictionary #integer  -- SGビット値 → 文字列
global sgOverlayTplCache = Dictionary #string   -- ラベル文字列 → ポリライン形状
global sgOverlayExtCache = Dictionary #string   -- ラベル文字列 → テキスト寸法
global sgOverlayGlyphs

-- ============================================================
-- 7セグ文字形状（1文字 = 1本のポリライン、単位座標 幅1 × 高さ1）
--   A B      A=(0,0) B=(1,0)
--   C D      C=(0,.5) D=(1,.5)
--   E F      E=(0,1) F=(1,1)   ※ y は下向き（スクリーン座標）
-- ============================================================
fn sgOverlayBuildGlyphs =
(
    local A = [0,0,0],   B = [1,0,0]
    local C = [0,0.5,0], D = [1,0.5,0]
    local E = [0,1,0],   F = [1,1,0]
    local g = Dictionary #string
    g["0"] = #(A,B,F,E,A)
    g["1"] = #(B,F)
    g["2"] = #(A,B,D,C,E,F)
    g["3"] = #(A,B,D,C,D,F,E)
    g["4"] = #(A,C,D,B,F)
    g["5"] = #(B,A,C,D,F,E)
    g["6"] = #(B,A,E,F,D,C)
    g["7"] = #(A,B,F)
    g["8"] = #(C,D,B,A,E,F,D)
    g["9"] = #(D,C,A,B,F,E)
    g["-"] = #(C,D)
    g["/"] = #(E,B)
    g[","] = #([0.5,1,0], [0.15,1.3,0])
    g
)
sgOverlayGlyphs = sgOverlayBuildGlyphs()

-- ------------------------------------------------------------
-- SGビット値 → "1,3,5"（結果はキャッシュ）
-- ------------------------------------------------------------
fn sgOverlayDecode sgBits =
(
    if hasDictValue sgOverlaySGStr sgBits then sgOverlaySGStr[sgBits]
    else
    (
        local s = ""
        if sgBits == 0 then s = "-"
        else
            for i = 1 to 32 where (bit.get sgBits i) do
                s += (if s.count == 0 then "" else ",") + (i as string)
        sgOverlaySGStr[sgBits] = s
        s
    )
)

-- ------------------------------------------------------------
-- ラベル文字列 → 中心原点のポリライン配列（サイズ変更時に破棄）
-- ------------------------------------------------------------
fn sgOverlayGetTemplate str sz =
(
    if hasDictValue sgOverlayTplCache str then sgOverlayTplCache[str]
    else
    (
        local w     = sz * 0.55
        local adv   = w + sz * 0.35
        local total = str.count * adv - sz * 0.35
        local x0    = -total / 2.0
        local y0    = -sz / 2.0
        local bold  = sz >= 14
        local tpl   = #()
        for i = 1 to str.count do
        (
            local key = str[i]
            if hasDictValue sgOverlayGlyphs key do
            (
                local ox = x0 + (i - 1) * adv
                local pl = for p in sgOverlayGlyphs[key] collect [ox + p.x * w, y0 + p.y * sz, 0]
                append tpl pl
                if bold do append tpl (for p in pl collect (p + [1,0,0]))
            )
        )
        sgOverlayTplCache[str] = tpl
        tpl
    )
)

-- ------------------------------------------------------------
-- テキスト寸法（キャッシュ）
-- ------------------------------------------------------------
fn sgOverlayTextExt str =
(
    if hasDictValue sgOverlayExtCache str then sgOverlayExtCache[str]
    else
    (
        local e = gw.getTextExtent str
        sgOverlayExtCache[str] = e
        e
    )
)

-- ------------------------------------------------------------
-- TurboSmooth / MeshSmooth のチェック
-- ------------------------------------------------------------
fn sgOverlayCheckTS obj =
(
    local tsMods = for m in obj.modifiers \
        where ((classof m == TurboSmooth) or (classof m == meshsmooth)) and m.enabled \
        collect m

    if tsMods.count > 0 do
    (
        local msg = "TurboSmooth / MeshSmooth が有効になっています。\n" + \
                    "スムージンググループを正しく確認するため、\n" + \
                    "モディファイヤをオフにしますか？"
        if (queryBox msg title:"SG Overlay") then
        (
            for m in tsMods do m.enabled = false
            completeRedraw()
        )
        else
        (
            messageBox ("TurboSmooth が有効のままだと、番号の表示位置が\n" + \
                        "スムージング後の形状とずれる場合があります。") title:"SG Overlay"
        )
    )
)

-- ------------------------------------------------------------
-- 比較ユーティリティ
-- ------------------------------------------------------------
fn sgOverlaySameTM a b =
(
    b != undefined and a.row1 == b.row1 and a.row2 == b.row2 and \
                       a.row3 == b.row3 and a.row4 == b.row4
)

fn sgOverlaySameBits a b =
(
    a.numberSet == b.numberSet and (a - b).isEmpty
)

fn sgOverlaySameArr a b =
(
    local same = (a.count == b.count)
    local i = 1
    while same and i <= a.count do
    (
        same = (a[i] == b[i])
        i += 1
    )
    same
)

-- ------------------------------------------------------------
-- 視点のシグネチャ（ビュー行列・ウィンドウ・投影結果の組）
-- ------------------------------------------------------------
fn sgOverlayViewSignature =
(
    gw.setTransform (matrix3 1)
    local vtm = viewport.getTM()
    #( vtm.row1, vtm.row2, vtm.row3, vtm.row4, \
       [gw.getWinSizeX(), gw.getWinSizeY(), viewport.activeViewport], \
       gw.transPoint [0,0,0],    gw.transPoint [1000,0,0], \
       gw.transPoint [0,1000,0], gw.transPoint [0,0,1000] )
)

-- ------------------------------------------------------------
-- 対象ノードの変更監視（SG・MatID はトポロジチャンネル）
-- ------------------------------------------------------------
fn sgOverlayWatch obj =
(
    deleteAllChangeHandlers id:#sgOverlayWatch
    when geometry obj changes id:#sgOverlayWatch do sgOverlayDataDirty = true
    when topology obj changes id:#sgOverlayWatch do sgOverlayDataDirty = true
)

-- ------------------------------------------------------------
-- 面の中心・法線を取得（未取得の面だけ）
-- ------------------------------------------------------------
fn sgOverlayFetchGeoEPoly obj faces =
(
    local todo = faces - sgOverlayFDoneGeo
    if not todo.isEmpty do
    (
        local FC = sgOverlayFC, FNrm = sgOverlayFN
        in coordsys world
        (
            for f in todo do
            (
                FC[f] = polyop.getFaceCenter obj f
                FNrm[f] = polyop.getFaceNormal obj f
            )
        )
        sgOverlayFDoneGeo += todo
    )
)

fn sgOverlayFetchGeoEditPoly cur obj faces =
(
    local todo = faces - sgOverlayFDoneGeo
    if not todo.isEmpty do
    (
        local tm = obj.objectTransform

        -- 座標系の自動判定（対象や TM が変わった時だけ）
        if sgOverlayUseTM == undefined do
        (
            local f1 = undefined
            for f in todo while f1 == undefined do f1 = f
            local v0  = cur.GetVertex (cur.GetFaceVertex f1 1 node:obj) node:obj
            local ctr = obj.center
            sgOverlayUseTM = (distance (v0 * tm) ctr) < (distance v0 ctr)
        )
        local useTM = sgOverlayUseTM
        local FC = sgOverlayFC, FNrm = sgOverlayFN
        local VP = sgOverlayVP, VD = sgOverlayVDone

        for f in todo do
        (
            local deg = cur.GetFaceDegree f node:obj
            local c = [0,0,0], n = [0,0,0]
            if deg > 0 do
            (
                -- 共有頂点はキャッシュから（1頂点につき GetVertex は1回だけ）
                local pts = for k = 1 to deg collect
                (
                    local vi = cur.GetFaceVertex f k node:obj
                    if not VD[vi] do
                    (
                        local v = cur.GetVertex vi node:obj
                        VP[vi] = if useTM then v * tm else v
                        VD[vi] = true
                    )
                    VP[vi]
                )
                for k = 1 to deg do
                (
                    c += pts[k]
                    n += cross pts[k] pts[if k == deg then 1 else k + 1]   -- Newell 法線
                )
                c /= deg
            )
            FC[f] = c
            FNrm[f] = n
        )
        sgOverlayFDoneGeo += todo
    )
)

-- ------------------------------------------------------------
-- SG・MatID を取得（画面に出す面だけ、遅延取得）
-- ------------------------------------------------------------
fn sgOverlayFetchAttr kind cur obj f =
(
    if kind == #ePoly then
    (
        sgOverlayFSG[f] = sgOverlayDecode (polyop.getFaceSmoothGroup obj f)
        sgOverlayFID[f] = (polyop.getFaceMatID obj f) as string
    )
    else
    (
        sgOverlayFSG[f] = sgOverlayDecode (cur.GetFaceSmoothingGroups f node:obj)
        sgOverlayFID[f] = (cur.GetFaceMaterial f node:obj) as string
    )
    sgOverlayFDoneAttr[f] = true
)

-- ------------------------------------------------------------
-- 選択面のクラスタリング（ワールド空間ボクセル）
--   選択・ジオメトリが変わった時だけ実行。視点変更時は再利用する
-- ------------------------------------------------------------
fn sgOverlayBuildClusters sel =
(
    local CC = #(), CR = #(), CRep = #(), CM = #()
    local k = sel.numberSet

    if k >= sgOverlayClusterMin do
    (
        local FC = sgOverlayFC

        -- 選択面中心のバウンディングボックス
        local x0 = 1e30, y0 = 1e30, z0 = 1e30
        local x1 = -1e30, y1 = -1e30, z1 = -1e30
        for f in sel do
        (
            local c = FC[f]
            if c.x < x0 do x0 = c.x
            if c.y < y0 do y0 = c.y
            if c.z < z0 do z0 = c.z
            if c.x > x1 do x1 = c.x
            if c.y > y1 do y1 = c.y
            if c.z > z1 do z1 = c.z
        )
        local ex = x1 - x0, ey = y1 - y0, ez = z1 - z0

        -- 1クラスタ平均 12 面程度になるボクセルサイズ（表面分布を想定）
        local area = ex * ey + ey * ez + ez * ex
        local s    = sqrt (area / (k / 12.0))
        local emax = amax #(ex, ey, ez)
        if s < emax / 1000.0 do s = emax / 1000.0    -- 各軸 1000 分割まで
        if s <= 0.0 do s = 1.0

        local nx  = ((ex / s) as integer) + 1
        local nxy = nx * (((ey / s) as integer) + 1)
        local d   = Dictionary #integer
        local SUM = #()

        for f in sel do
        (
            local c   = FC[f]
            local key = ((c.x - x0) / s) as integer
            key += (((c.y - y0) / s) as integer) * nx
            key += (((c.z - z0) / s) as integer) * nxy
            if hasDictValue d key then
            (
                local i = d[key]
                append CM[i] f
                SUM[i] = SUM[i] + c
            )
            else
            (
                append CM #(f)
                append SUM (c + [0,0,0])
                d[key] = CM.count
            )
        )

        -- 中心・半径・代表面（中心に最も近い面）
        for i = 1 to CM.count do
        (
            local mem  = CM[i]
            local ctr  = SUM[i] / mem.count
            local r    = 0.0
            local rep  = mem[1]
            local best = 1e30
            for f in mem do
            (
                local dd = distance FC[f] ctr
                if dd > r do r = dd
                if dd < best do ( best = dd; rep = f )
            )
            append CC ctr
            append CR r
            append CRep rep
        )
    )

    sgOverlayClC = CC
    sgOverlayClR = CR
    sgOverlayClRep = CRep
    sgOverlayClM = CM
)

-- ------------------------------------------------------------
-- ラベルを画面ポリラインとして追加（ベクター）
-- ------------------------------------------------------------
fn sgOverlayAppendLabel dst str p sz =
(
    for pl in (sgOverlayGetTemplate str sz) do
        append dst (for q in pl collect (q + p))
)

-- ------------------------------------------------------------
-- 画面描画データの再構築（クラスタ除外 → 面ごとのカリング・間引き）
-- ------------------------------------------------------------
fn sgOverlayBuildScreen kind cur obj sel =
(
    local scrSG = #(), scrID = #()
    local tpSG = #(), tsSG = #(), tpID = #(), tsID = #()
    gw.setTransform (matrix3 1)

    local textMode = sgOverlayTextMode
    local sz = sgOverlaySize
    if textMode do
    (
        local h = (sgOverlayTextExt "0").y
        sz = if h > 0 then h else 12
    )
    local mode   = sgOverlayMode
    local winX   = gw.getWinSizeX()
    local winY   = gw.getWinSizeY()
    local marg   = sz * 3.0
    local persp  = gw.isPerspView()
    local vinv   = inverse (viewport.getTM())
    local camPos = vinv.row4
    local camX   = vinv.row1
    local camZ   = vinv.row3                 -- ビューは -Z 方向を向く
    local cull   = sgOverlayCullBack
    local thin   = sgOverlayThin
    local cellW  = sz * 2.0
    local cellH  = if mode == 3 then sz * 3.2 else sz * 1.6
    local cols   = (((winX + marg * 2) / cellW) as integer) + 1
    local used   = #{}
    local offS   = if mode == 3 then -sz * 0.8 else 0.0
    local offI   = if mode == 3 then  sz * 0.8 else 0.0
    local FC     = sgOverlayFC
    local FNrm     = sgOverlayFN

    -- ---- ① クラスタ単位の絞り込み ----
    local cand = sel
    local CC   = sgOverlayClC
    if CC.count > 0 do
    (
        local CR = sgOverlayClR, CRep = sgOverlayClRep, CM = sgOverlayClM
        local minCell = amin cellW cellH
        cand = #()
        for i = 1 to CC.count do
        (
            local c = CC[i]
            local r = CR[i]
            local depth = if persp then -(dot (c - camPos) camZ) else 1e30
            if depth > -r do                          -- 完全にカメラ背後なら除外
            (
                if depth <= r * 1.01 then
                    join cand CM[i]                   -- カメラに近すぎる：全展開
                else
                (
                    local sp = gw.transPoint c
                    local rp = abs ((gw.transPoint (c + camX * r)).x - sp.x)
                    if not (sp.x + rp < -marg or sp.x - rp > winX + marg or \
                            sp.y + rp < -marg or sp.y - rp > winY + marg) do
                    (
                        -- 画面上で1セルより小さい → 代表面だけで十分
                        if thin and rp * 2.0 < minCell then append cand CRep[i]
                        else join cand CM[i]
                    )
                )
            )
        )
    )

    -- ---- ② 面ごとの判定 ----
    local nDrawn = 0
    for f in cand do
    (
        local c   = FC[f]
        local vis = true

        if persp then
        (
            local toC = c - camPos
            if (dot toC camZ) >= 0 then vis = false
            else if cull and (dot FNrm[f] toC) > 0 do vis = false
        )
        else if cull and (dot FNrm[f] camZ) < 0 do vis = false

        if vis do
        (
            local sp = gw.transPoint c
            local x  = sp.x
            local y  = sp.y

            if x < -marg or x > winX + marg or y < -marg or y > winY + marg then
                vis = false
            else if thin do
            (
                local key = ((((y + marg) / cellH) as integer) * cols) + \
                            (((x + marg) / cellW) as integer) + 1
                if used[key] then vis = false else used[key] = true
            )

            if vis do
            (
                if not sgOverlayFDoneAttr[f] do sgOverlayFetchAttr kind cur obj f
                if textMode then
                (
                    if mode != 2 do
                    (
                        local s = sgOverlayFSG[f]
                        local e = sgOverlayTextExt s
                        append tpSG [x - e.x / 2.0, y + offS + e.y / 2.0, 0]
                        append tsSG s
                    )
                    if mode != 1 do
                    (
                        local s = sgOverlayFID[f]
                        local e = sgOverlayTextExt s
                        append tpID [x - e.x / 2.0, y + offI + e.y / 2.0, 0]
                        append tsID s
                    )
                )
                else
                (
                    if mode != 2 do sgOverlayAppendLabel scrSG sgOverlayFSG[f] [x, y + offS, 0] sz
                    if mode != 1 do sgOverlayAppendLabel scrID sgOverlayFID[f] [x, y + offI, 0] sz
                )
                nDrawn += 1
            )
        )
    )

    sgOverlayScrSG = scrSG
    sgOverlayScrID = scrID
    sgOverlayTxPSG = tpSG
    sgOverlayTxSSG = tsSG
    sgOverlayTxPID = tpID
    sgOverlayTxSID = tsID

    local nCand = if classof cand == BitArray then cand.numberSet else cand.count
    try (sgOverlayRoll.lbStat.text = "選択 " + (sel.numberSet as string) + \
                                     " / 判定 " + (nCand as string) + \
                                     " / 表示 " + (nDrawn as string)) catch()
)

-- ------------------------------------------------------------
-- キャッシュ済みデータの描画
-- ------------------------------------------------------------
fn sgOverlayPaint =
(
    local total = sgOverlayScrSG.count + sgOverlayScrID.count + \
                  sgOverlayTxPSG.count + sgOverlayTxPID.count
    if total > 0 do
    (
        gw.setTransform (matrix3 1)
        if sgOverlayScrSG.count > 0 do
        (
            gw.setColor #line sgOverlayColorSG
            for pl in sgOverlayScrSG do gw.wPolyline pl false
        )
        if sgOverlayScrID.count > 0 do
        (
            gw.setColor #line sgOverlayColorID
            for pl in sgOverlayScrID do gw.wPolyline pl false
        )
        if sgOverlayTxPSG.count > 0 do
        (
            local P = sgOverlayTxPSG, S = sgOverlayTxSSG, col = sgOverlayColorSG
            for i = 1 to P.count do gw.wText P[i] S[i] color:col
        )
        if sgOverlayTxPID.count > 0 do
        (
            local P = sgOverlayTxPID, S = sgOverlayTxSID, col = sgOverlayColorID
            for i = 1 to P.count do gw.wText P[i] S[i] color:col
        )
        gw.enlargeUpdateRect #whole
        gw.updateScreen()
    )
)

-- ------------------------------------------------------------
-- ビューポート描画コールバック本体
-- ------------------------------------------------------------
fn sgOverlayDraw =
(
    if sgOverlayActive and selection.count == 1 and isValidNode selection[1] do
    (
        local obj  = selection[1]
        local cur  = try (modPanel.getCurrentObject()) catch (undefined)
        local kind = #none

        if classof cur == Edit_Poly then
        (
            local lvl = cur.GetEPolySelLevel()
            if lvl == #Face or lvl == #Element do kind = #editPoly
        )
        else if (classof cur == Editable_Poly) and (subObjectLevel != undefined) and \
                (subObjectLevel == 4 or subObjectLevel == 5) do kind = #ePoly

        if kind != #none do
        (
            -- ① 対象の切り替え
            if obj != sgOverlayNode or cur != sgOverlayOwner do
            (
                sgOverlayWatch obj
                sgOverlayNode      = obj
                sgOverlayOwner     = cur
                sgOverlayUseTM     = undefined
                sgOverlayDataDirty = true
            )

            -- ② トランスフォーム変更（面データはワールド座標で保持）
            local tm = obj.objectTransform
            if not (sgOverlaySameTM tm sgOverlayTM) do
            (
                sgOverlayTM        = tm
                sgOverlayUseTM     = undefined
                sgOverlayDataDirty = true
            )

            -- ③ 面データの破棄（取得済みフラグのリセットのみ）
            if sgOverlayDataDirty do
            (
                sgOverlayFDoneGeo     = #{}
                sgOverlayFDoneAttr    = #{}
                sgOverlayVDone        = #{}
                sgOverlayDataDirty    = false
                sgOverlayClusterDirty = true
                sgOverlayScreenDirty  = true
            )

            -- ④ 選択の変化
            local sel = if kind == #ePoly then polyop.getFaceSelection obj \
                                          else cur.GetSelection #Face node:obj
            if not (sgOverlaySameBits sel sgOverlayPrevSel) do
            (
                sgOverlayPrevSel      = sel
                sgOverlayClusterDirty = true
                sgOverlayScreenDirty  = true
            )

            -- ⑤ 視点の変化
            local sig         = sgOverlayViewSignature()
            local viewChanged = not (sgOverlaySameArr sig sgOverlayViewSig)

            if viewChanged and sgOverlaySkipNav and not mouse.buttonStates.isEmpty then
            (
                sgOverlayViewSig = #()      -- 離した後の再描画で必ず再構築
            )
            else
            (
                if viewChanged do
                (
                    sgOverlayViewSig     = sig
                    sgOverlayScreenDirty = true
                )

                -- ⑥ 必要な時だけ再構築
                if sgOverlayScreenDirty do
                (
                    if kind == #ePoly then sgOverlayFetchGeoEPoly obj sel
                                      else sgOverlayFetchGeoEditPoly cur obj sel
                    if sgOverlayClusterDirty do
                    (
                        sgOverlayBuildClusters sel
                        sgOverlayClusterDirty = false
                    )
                    sgOverlayBuildScreen kind cur obj sel
                    sgOverlayScreenDirty = false
                )

                -- ⑦ 描画
                sgOverlayPaint()
            )
        )
    )
)

-- ------------------------------------------------------------
-- キャッシュ全破棄（メモリ解放）
-- ------------------------------------------------------------
fn sgOverlayClearCache =
(
    sgOverlayNode      = undefined
    sgOverlayOwner     = undefined
    sgOverlayTM        = undefined
    sgOverlayUseTM     = undefined
    sgOverlayFDoneGeo  = #{}
    sgOverlayFDoneAttr = #{}
    sgOverlayVDone     = #{}
    sgOverlayFC  = #()
    sgOverlayFN  = #()
    sgOverlayFSG = #()
    sgOverlayFID = #()
    sgOverlayVP  = #()
    sgOverlayClC = #()
    sgOverlayClR = #()
    sgOverlayClRep = #()
    sgOverlayClM = #()
    sgOverlayPrevSel = #{}
    sgOverlayViewSig = #()
    sgOverlayScrSG = #()
    sgOverlayScrID = #()
    sgOverlayTxPSG = #()
    sgOverlayTxSSG = #()
    sgOverlayTxPID = #()
    sgOverlayTxSID = #()
    sgOverlayDataDirty    = true
    sgOverlayClusterDirty = true
    sgOverlayScreenDirty  = true
)

-- ------------------------------------------------------------
-- 操作用ダイアログ
-- ------------------------------------------------------------
rollout sgOverlayRoll "SG / MatID Overlay" width:240
(
    checkbutton  cbActive "オーバーレイ表示 ON / OFF" width:220 height:28
    radiobuttons rbMode   "表示内容 :" \
                 labels:#("スムージンググループ", "マテリアルID", "両方（上:SG / 下:ID）") \
                 default:1 align:#left columns:1
    radiobuttons rbDraw   "描画方式 :" \
                 labels:#("ベクター（サイズ可変）", "テキスト（高速・サイズ固定）") \
                 default:1 align:#left columns:1
    slider       sdSize   "文字サイズ :" range:[6,40,12] type:#integer width:220 align:#left
    colorpicker  cpSG     "SG の色 :"    color:(color 255 255 0) fieldwidth:50 align:#left
    colorpicker  cpID     "MatID の色 :" color:(color 0 200 255) fieldwidth:50 align:#left

    group "パフォーマンス"
    (
        checkbox chkBack "裏面のポリゴンは表示しない" checked:true
        checkbox chkThin "重なるラベルを間引く"       checked:true
        checkbox chkNav  "視点ドラッグ中は描画しない" checked:true
        button   btnRef  "キャッシュを再構築" width:200
        label    lbStat  "" align:#left width:210
    )

    label lbInfo  "※ Editable Poly / ポリゴン編集(Edit Poly)" align:#left offset:[0,4]
    label lbInfo2 "   のポリゴン・要素レベルで有効" align:#left

    fn refresh rebuild:false =
    (
        if rebuild do sgOverlayDataDirty = true
        sgOverlayScreenDirty = true
        completeRedraw()
    )

    on cbActive changed state do
    (
        sgOverlayActive = state
        if state and selection.count == 1 do sgOverlayCheckTS selection[1]
        refresh rebuild:true
    )
    on rbMode changed idx do
    (
        sgOverlayMode = idx
        refresh()
    )
    on rbDraw changed idx do
    (
        sgOverlayTextMode = (idx == 2)
        sdSize.enabled    = not sgOverlayTextMode
        sgOverlayExtCache = Dictionary #string
        refresh()
    )
    on sdSize changed val do
    (
        sgOverlaySize     = val
        sgOverlayTplCache = Dictionary #string
        refresh()
    )
    on cpSG changed col do ( sgOverlayColorSG = col; completeRedraw() )
    on cpID changed col do ( sgOverlayColorID = col; completeRedraw() )
    on chkBack changed state do ( sgOverlayCullBack = state; refresh() )
    on chkThin changed state do ( sgOverlayThin     = state; refresh() )
    on chkNav  changed state do ( sgOverlaySkipNav  = state; refresh() )
    on btnRef pressed do refresh rebuild:true

    on sgOverlayRoll close do
    (
        sgOverlayActive = false
        try (unregisterRedrawViewsCallback sgOverlayDraw) catch()
        deleteAllChangeHandlers id:#sgOverlayWatch
        sgOverlayClearCache()
        completeRedraw()
    )
)

registerRedrawViewsCallback sgOverlayDraw
createDialog sgOverlayRoll
