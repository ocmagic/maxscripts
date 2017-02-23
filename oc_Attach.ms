sel = for i in selection collect i
newP = convertToPoly sel[1]
for i=2 to sel.count do
	(
		if superclassof sel[i] == GeometryClass do
		(
			newP.EditablePoly.attach sel[i] newP
		)
		selectmore newP
		newP.weldThreshold = 0.001
	)
