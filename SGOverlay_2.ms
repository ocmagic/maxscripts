/*  SGOverlay.ms  (v3 : 高速化版)
    ------------------------------------------------------------
    Editable Poly / ポリゴン編集(Edit Poly) のポリゴン・要素レベルで、
    選択中の各ポリゴンの中心に以下をオーバーレイ表示します。

      ・スムージンググループ番号（複数は "1,3" 形式、未割当は "-"）
      ・マテリアルID
      ・両方（上段=SG、下段=MatID）

    v3 の変更点（高ポリゴン対策）
      ・面データ（中心・法線・SG・MatID）をキャッシュし、未取得の面だけ取得
        （ジオメトリ/トポロジ/トランスフォームが変わった時だけ破棄）
      ・画面用ポリラインもキャッシュし、視点・選択・設定が変わらない限り
        再計算しない（ホバーのプリセレクション等による再描画はほぼ無負荷）
      ・画面外 / カメラ背後 / 裏面のポリゴンをスキップ
      ・スクリーン上で重なるラベルを間引き、描画数を画面面積で頭打ちに
      ・7セグ文字を「1文字 = 1ポリライン」で描画（描画コール数を大幅削減）
      ・SG文字列・文字形状を Dictionary でキャッシュ
      ・視点操作（マウスドラッグ）中は描画を省略するオプション

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
global sgOverlayActive   = false
global sgOverlayMode     = 1                    -- 1:SG  2:MatID  3:両方
global sgOverlaySize     = 12                   -- 文字の高さ(px)
global sgOverlayColorSG  = color 255 255 0
global sgOverlayColorID  = color 0 200 255
global sgOverlayCullBack = true                 -- 裏面を表示しない
global sgOverlayThin     = true                 -- 重なりを間引く
global sgOverlaySkipNav  = true                 -- 視点操作中は描画しない

-- ============================================================
-- キャッシュ
-- ============================================================
global sgOverlayNode        = undefined         -- 対象ノード
global sgOverlayOwner       = undefined         -- 対象（Editable_Poly or Edit_Poly）
global sgOverlayTM          = undefined         -- 前回の objectTransform
global sgOverlayUseTM       = undefined         -- Edit_Poly 座標系判定結果
global sgOverlayDataDirty   = true              -- 面データを破棄すべきか
global sgOverlayScreenDirty = true              -- 画面ポリラインを作り直すべきか

global sgOverlayFDoneGeo    = #{}               -- 中心・法線 取得済みの面
global sgOverlayFDoneAttr   = #{}               -- SG・MatID 取得済みの面
global sgOverlayFC          = #()               -- 面中心（ワールド）
global sgOverlayFN          = #()               -- 面法線（ワールド、非正規化）
global sgOverlayFSG         = #()               -- SG 文字列
global sgOverlayFID         = #()               -- MatID 文字列

global sgOverlayPrevSel     = #{}
global sgOverlayViewSig     = #()
global sgOverlayScrSG       = #()               -- 画面ポリライン（SG色）
global sgOverlayScrID       = #()               -- 画面ポリライン（MatID色）

global sgOverlaySGStr       = Dictionary #integer   -- SGビット値 → 文字列
global sgOverlayTplCache    = Dictionary #string    -- ラベル文字列 → ポリライン形状
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
--   FOV / オルソのズームも投影点の変化で検出される
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
-- 対象ノードの変更監視（変更があれば面データを破棄）
--   SG・MatID はトポロジチャンネルに含まれる
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
        in coordsys world
        (
            for f in todo do
            (
                sgOverlayFC[f] = polyop.getFaceCenter obj f
                sgOverlayFN[f] = polyop.getFaceNormal obj f
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

        -- 座標系の自動判定（GetVertex がワールド/ローカルどちらを返すか）
        -- 対象や TM が変わった時だけ判定する
        if sgOverlayUseTM == undefined do
        (
            local f1 = undefined
            for f in todo while f1 == undefined do f1 = f
            local v0  = cur.GetVertex (cur.GetFaceVertex f1 1 node:obj) node:obj
            local ctr = obj.center
            sgOverlayUseTM = (distance (v0 * tm) ctr) < (distance v0 ctr)
        )
        local useTM = sgOverlayUseTM

        for f in todo do
        (
            local deg = cur.GetFaceDegree f node:obj
            local c = [0,0,0], n = [0,0,0]
            if deg > 0 do
            (
                local pts = for k = 1 to deg collect
                (
                    local v = cur.GetVertex (cur.GetFaceVertex f k node:obj) node:obj
                    if useTM then v * tm else v
                )
                for k = 1 to deg do
                (
                    c += pts[k]
                    n += cross pts[k] pts[if k == deg then 1 else k + 1]   -- Newell 法線
                )
                c /= deg
            )
            sgOverlayFC[f] = c
            sgOverlayFN[f] = n
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
-- ラベルを画面ポリラインとして追加
-- ------------------------------------------------------------
fn sgOverlayAppendLabel dst str p sz =
(
    for pl in (sgOverlayGetTemplate str sz) do
        append dst (for q in pl collect (q + p))
)

-- ------------------------------------------------------------
-- 画面ポリラインの再構築（カリング・間引き込み）
-- ------------------------------------------------------------
fn sgOverlayBuildScreen kind cur obj sel =
(
    sgOverlayScrSG = #()
    sgOverlayScrID = #()
    gw.setTransform (matrix3 1)

    local sz     = sgOverlaySize
    local mode   = sgOverlayMode
    local winX   = gw.getWinSizeX()
    local winY   = gw.getWinSizeY()
    local marg   = sz * 3.0
    local persp  = gw.isPerspView()
    local vinv   = inverse (viewport.getTM())
    local camPos = vinv.row4
    local camZ   = vinv.row3                 -- ビューは -Z 方向を向く
    local cull   = sgOverlayCullBack
    local thin   = sgOverlayThin
    local cellW  = sz * 2.0
    local cellH  = if mode == 3 then sz * 3.2 else sz * 1.6
    local cols   = ((floor ((winX + marg * 2) / cellW)) as integer) + 1
    local used   = #{}
    local offS   = if mode == 3 then [0, -sz * 0.8, 0] else [0,0,0]
    local offI   = if mode == 3 then [0,  sz * 0.8, 0] else [0,0,0]
    local nDrawn = 0

    for f in sel do
    (
        local c   = sgOverlayFC[f]
        local vis = true

        -- カメラ背後 / 裏面
        if persp then
        (
            local toC = c - camPos
            if (dot toC camZ) >= 0 then vis = false
            else if cull and (dot sgOverlayFN[f] toC) > 0 do vis = false
        )
        else if cull and (dot sgOverlayFN[f] camZ) < 0 do vis = false

        if vis do
        (
            local sp = gw.transPoint c
            local x  = sp.x
            local y  = sp.y

            -- 画面外
            if x < -marg or x > winX + marg or y < -marg or y > winY + marg then
                vis = false
            -- 重なり間引き（セルごとに1ラベル）
            else if thin do
            (
                local key = ((floor ((y + marg) / cellH)) as integer) * cols + \
                            ((floor ((x + marg) / cellW)) as integer) + 1
                if used[key] then vis = false else used[key] = true
            )

            if vis do
            (
                if not sgOverlayFDoneAttr[f] do sgOverlayFetchAttr kind cur obj f
                local p0 = [x, y, 0]
                if mode != 2 do sgOverlayAppendLabel sgOverlayScrSG sgOverlayFSG[f] (p0 + offS) sz
                if mode != 1 do sgOverlayAppendLabel sgOverlayScrID sgOverlayFID[f] (p0 + offI) sz
                nDrawn += 1
            )
        )
    )

    try (sgOverlayRoll.lbStat.text = "選択 " + (sel.numberSet as string) + \
                                     "  /  表示 " + (nDrawn as string)) catch()
)

-- ------------------------------------------------------------
-- キャッシュ済みポリラインの描画
-- ------------------------------------------------------------
fn sgOverlayPaint =
(
    if sgOverlayScrSG.count > 0 or sgOverlayScrID.count > 0 do
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

            -- ③ 面データの破棄（O(1)：取得済みフラグをリセットするだけ）
            if sgOverlayDataDirty do
            (
                sgOverlayFDoneGeo    = #{}
                sgOverlayFDoneAttr   = #{}
                sgOverlayDataDirty   = false
                sgOverlayScreenDirty = true
            )

            -- ④ 選択の変化
            local sel = if kind == #ePoly then polyop.getFaceSelection obj \
                                          else cur.GetSelection #Face node:obj
            if not (sgOverlaySameBits sel sgOverlayPrevSel) do
            (
                sgOverlayPrevSel     = sel
                sgOverlayScreenDirty = true
            )

            -- ⑤ 視点の変化
            local sig         = sgOverlayViewSignature()
            local viewChanged = not (sgOverlaySameArr sig sgOverlayViewSig)

            if viewChanged and sgOverlaySkipNav and not mouse.buttonStates.isEmpty then
            (
                -- 視点ドラッグ中は描画を省略（離した後の再描画で再構築）
                sgOverlayViewSig = #()
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
    sgOverlayFC  = #()
    sgOverlayFN  = #()
    sgOverlayFSG = #()
    sgOverlayFID = #()
    sgOverlayPrevSel = #{}
    sgOverlayViewSig = #()
    sgOverlayScrSG   = #()
    sgOverlayScrID   = #()
    sgOverlayDataDirty   = true
    sgOverlayScreenDirty = true
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
    slider       sdSize   "文字サイズ :" range:[6,40,12] type:#integer width:220 align:#left
    colorpicker  cpSG     "SG の色 :"    color:(color 255 255 0) fieldwidth:50 align:#left
    colorpicker  cpID     "MatID の色 :" color:(color 0 200 255) fieldwidth:50 align:#left

    group "パフォーマンス"
    (
        checkbox chkBack "裏面のポリゴンは表示しない" checked:true
        checkbox chkThin "重なるラベルを間引く"       checked:true
        checkbox chkNav  "視点ドラッグ中は描画しない" checked:true
        button   btnRef  "キャッシュを再構築" width:200
        label    lbStat  "" align:#left
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
