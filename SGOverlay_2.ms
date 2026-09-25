    local key = (SGO4.size as string) + ":" + str
    if hasDictValue SGO4.templates key then SGO4.templates[key]
    else
    (
        local sz = SGO4.size, width = sz * 0.55, advance = sz * 0.9
        local x0 = -(str.count * advance - sz * 0.35) / 2.0
        local lines = #(), bounds = [1e9,1e9,-1e9,-1e9]
        for i = 1 to str.count do
        (
            local glyph = SGO4.glyphs[str[i]]
            if glyph != undefined do
            (
                local pl = for p in glyph collect [x0 + (i-1)*advance + p.x*width, -sz/2.0 + p.y*sz, 0]
                append lines pl
                if sz >= 14 do append lines (for p in pl collect (p + [1,0,0]))
            )
        )
        for pl in lines do for p in pl do
        (
            bounds.x = amin bounds.x p.x; bounds.y = amin bounds.y p.y
            bounds.z = amax bounds.z p.x; bounds.w = amax bounds.w p.y
        )
        if lines.count == 0 do bounds = [0,0,0,0]
        if SGO4.templates.count >= 2048 do SGO4.templates = Dictionary #string
        local result = #(lines,bounds)
        SGO4.templates[key] = result
        result
    )
)
fn sg4Rect strSG strID p =
(
    local rect = [1e9,1e9,-1e9,-1e9]
    for channel = 1 to 2 where (if channel == 1 then SGO4.mode != 2 else SGO4.mode != 1) do
    (
        local tpl = sg4Template (if channel == 1 then strSG else strID)
        local b = tpl[2]
        local dy = if SGO4.mode == 3 then (if channel == 1 then -0.8 else 0.8)*SGO4.size else 0.0
        rect.x = amin rect.x (b.x + p.x); rect.z = amax rect.z (b.z + p.x)
        rect.y = amin rect.y (b.y + p.y + dy); rect.w = amax rect.w (b.w + p.y + dy)
    )
    rect + [-2,-2,2,2]
)
-- Reserve every grid cell touched by the full label rectangle.
-- Conservative spacing intentionally prevents adjacent-cell label overlap.
fn sg4ReserveRect rect =
(
    local x1 = (floor (rect.x / SGO4.cell)) as integer
    local x2 = (floor (rect.z / SGO4.cell)) as integer
    local y1 = (floor (rect.y / SGO4.cell)) as integer
    local y2 = (floor (rect.w / SGO4.cell)) as integer
    local free = true
    for y = y1 to y2 while free do
        for x = x1 to x2 while free do
            if SGO4.used[y*SGO4.cols+x+1] do free = false
    if free do
        for y = y1 to y2 do for x = x1 to x2 do SGO4.used[y*SGO4.cols+x+1] = true
    free
)
fn sg4Append dst str p =
(
    local tpl = sg4Template str
    for pl in tpl[1] do append dst (for q in pl collect (q+p))
)
-- EditPolyMod returns object-space vertices. No distance-to-center guessing.
-- objectTransform includes object offsets (pivot edits) as well as node TM.
fn sg4GetVertex index =
(
    if hasDictValue SGO4.verts index then SGO4.verts[index]
    else
    (
        local p = if SGO4.kind == #ePoly then polyop.getVert SGO4.owner index
                  else EditPolyMod.GetVertex SGO4.owner index node:SGO4.node
        p = p * SGO4.tm
        SGO4.verts[index] = p
        p
    )
)
fn sg4GetFace index =
(
    if hasDictValue SGO4.geo index then SGO4.geo[index]
    else
    (
        local indices
        if SGO4.kind == #ePoly then indices = polyop.getFaceVerts SGO4.owner index
        else
        (
            local degree = EditPolyMod.GetFaceDegree SGO4.owner index node:SGO4.node
            indices = for k = 1 to degree collect (EditPolyMod.GetFaceVertex SGO4.owner index k node:SGO4.node)
        )
        local result = undefined
        if indices.count >= 3 do
        (
            local points = for i in indices collect sg4GetVertex i
            local origin = points[1], center = [0,0,0], normal = [0,0,0]
            -- Work relative to a vertex to avoid cancellation far from origin.
            for k = 1 to points.count do
            (
                local a = points[k]-origin
                local b = points[if k == points.count then 1 else k+1]-origin
                center += a
                normal += cross a b
            )
            result = #(origin + center/points.count, normal)
        )
        SGO4.geo[index] = result
        result
    )
)
fn sg4GetAttr index =
(
    if hasDictValue SGO4.attrs index then SGO4.attrs[index]
    else
    (
        local bits, matID
        if SGO4.kind == #ePoly then
        (
            bits = polyop.getFaceSmoothGroup SGO4.owner index
            matID = polyop.getFaceMatID SGO4.owner index
        )
        else
        (
            bits = EditPolyMod.GetFaceSmoothingGroups SGO4.owner index node:SGO4.node
            matID = EditPolyMod.GetFaceMaterial SGO4.owner index node:SGO4.node
        )
        local result = #(sg4Decode bits, matID as string)
        SGO4.attrs[index] = result
        result
    )
)
fn sg4ViewSignature =
(
    gw.setTransform (matrix3 1)
    local vtm = viewport.getTM(), invView = inverse vtm
    -- Sample points in FRONT of the view, never at the eye or world origin.
    #((viewport.getHWnd()), vtm.row1, vtm.row2, vtm.row3, vtm.row4,
      (gw.getWinSizeX applyUIScaling:false), (gw.getWinSizeY applyUIScaling:false),
      (gw.isPerspView()),
      (gw.transPoint ([0,0,-100]*invView) applyUIScaling:false),
      (gw.transPoint ([100,100,-100]*invView) applyUIScaling:false))
)
fn sg4StartScreen sel =
(
    sg4ClearScreen()
    SGO4.faces = sel as array
    SGO4.width = gw.getWinSizeX applyUIScaling:false
    SGO4.height = gw.getWinSizeY applyUIScaling:false
    SGO4.cols = ((ceil (SGO4.width / (SGO4.cell as float))) as integer) + 1
    local invView = inverse (viewport.getTM())
    SGO4.camPos = invView.row4; SGO4.camZ = invView.row3
    SGO4.perspective = gw.isPerspView()
    SGO4.pending = SGO4.faces.count > 0
    SGO4.dirtyScreen = false
)
fn sg4ProcessFace f =
(
    if f < 1 or f > SGO4.faceCount then return false
    local data = sg4GetFace f
    if data == undefined then return false
    local center = data[1], normal = data[2]
    if (dot normal normal) <= 1e-20 then return false
    if SGO4.perspective then
    (
        local toFace = center - SGO4.camPos
        if (dot toFace SGO4.camZ) >= -0.00001 then return false
        if SGO4.cullBack and (dot normal toFace) > 0 then return false
    )
    else if SGO4.cullBack and (dot normal SGO4.camZ) < 0 then return false
    local sp = gw.transPoint center applyUIScaling:false
    if sp.x < 0 or sp.y < 0 or sp.x >= SGO4.width or sp.y >= SGO4.height then return false
    local labels = sg4GetAttr f
    local pos = [sp.x,sp.y,0]
    local rect = sg4Rect labels[1] labels[2] pos
    -- wPolyline has no clipping: reject the ENTIRE label at viewport edges.
    if rect.x < 1 or rect.y < 1 or rect.z >= SGO4.width-1 or rect.w >= SGO4.height-1 then return false
    if SGO4.thin and not (sg4ReserveRect rect) then return false
    local dy = if SGO4.mode == 3 then SGO4.size * 0.8 else 0.0
    if SGO4.mode != 2 do sg4Append SGO4.screenSG labels[1] (pos+[0,-dy,0])
    if SGO4.mode != 1 do sg4Append SGO4.screenID labels[2] (pos+[0,dy,0])
    SGO4.drawn += 1
    true
)
