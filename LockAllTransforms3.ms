--選択対象が1つのときにしか通らないので、複数選択したときに通るようにしたい。
for obj in selection do 
(
    j = 0 --変数jを初期化
    lockArr = getTransformLockFlags obj --選択してるもののTransformLockFlagsの配列を得る
    for i=1 to lockArr.count do --配列の中身を見て
    (
        if lockArr[i] == true then --trueだったらjに1足していく
        (
            j += 1
        )
        else
        (
            j += 0 --falseなら0を足す
        )
    )

    -- jが0ならロックのフラグは全く無いので、全項目をロックするようにして、
    -- jが0以外なら何処かにロックがあるので、それをオフにする

    if j == 0 then
    (
        setTransformLockFlags obj #all
    )
    else
    (
        setTransformLockFlags obj #none
    )
)
