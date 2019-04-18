
# Convert Excel Serial Date to time.Time

```
package main

import (
  "fmt"
  "math"
  "time"
)

func calc(serial float64) time.Time {
  unixtime := int64(math.Floor(math.Max(0, (serial-25569)*86400+0.5)))
  t := time.Unix(unixtime, 0)
  loc, _ := time.LoadLocation("UTC")
  return t.In(loc)
}

func main() {
  i := 43374.10759

  fmt.Println(calc(i))
}

```

