# Vector

## Copy vector to array

```
std::copy(vec.begin(), vec.end(), arr);
```

`std::copy` write every element of a vector even if a array don't have enough size.

```
  int ints[] = {};

  std::vector<int> v;
  v.push_back(10);
  v.push_back(20);
  v.push_back(30);
  std::copy(v.begin(), v.end(), ints);

  std::cout << ints[2] << std::endl;
	// => 30
```

