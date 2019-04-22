# Serialize Data Directly


```go

type User struct {
	hp int
	atk int
}

buffer := [64]byte{}
p := unsafe.Pointer(&buffer)
((*User)(p)).hp = 10
((*User)(p)).atk = 20

var u User
fmt.Println(buffer[0:unsafe.Sizeof(u)])
// => [10 0 0 0 0 0 0 0 20 0 0 0 0 0 0 0]

```
