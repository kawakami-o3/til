#!/bin/sh

#set -eux

for i in *high*.c;
do
  gcc $i
  ./a.out data.bin data2.bin
  diff data.bin data2.bin
done

echo

for i in *low*.c;
do
  gcc $i
  ./a.out data.bin data2.bin
  diff data.bin data2.bin
done


