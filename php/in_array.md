# in_array の話

PHP5からPHP7になってin_arrayが速くなっているという話をソースを参照しながら掘り下げてみる。

ざっくり何が変わって速くなっているかを言ってしまうと、連想配列の実装が大きく変わったためによる。
PHP7のリリース前後に解説が多数でているので検索してみるとすぐに見つけることができる。
たとえば、 https://www.slideshare.net/hnw/php7-52408724 .

## PHP5とPHP7で計測

まず、以下のようなスクリプトで処理時間を計測してみる。

```php
<?php

//$n = 100000;
//$trial = 100;

$n = 100;
$trial = 100000;

$a = [];
for ($i=0 ; $i<$n ; $i++) {
    $a[] = $i;
}

$time = microtime(true);

$b = 0;
for ($i=0 ; $i<$trial ; $i++) {
    if (in_array($n/2, $a, true)) {
        $b ++;
    }
}

$result = microtime(true) - $time;

echo "{$result}\n";
```

手元の環境では

| バージョン | 時間(s) |
----|----
| 5.6.40 | 0.052852153778076 |
| 7.4.14 | 0.028527021408081 |

要素数が多いとより差が大きくなるが、2倍ほど速くなっていることがわかる。

## PHP5のin_array実装

php-5.6.40/ext/standard/array.c

```c
/* void php_search_array(INTERNAL_FUNCTION_PARAMETERS, int behavior)
 * 0 = return boolean
 * 1 = return key
 */
static void php_search_array(INTERNAL_FUNCTION_PARAMETERS, int behavior) /* {{{ */
{
	zval *value,				/* value to check for */
		 *array,				/* array to check in */
		 **entry,				/* pointer to array entry */
		  res;					/* comparison result */
	HashPosition pos;			/* hash iterator */
	zend_bool strict = 0;		/* strict comparison or not */
	int (*is_equal_func)(zval *, zval *, zval * TSRMLS_DC) = is_equal_function;

	if (zend_parse_parameters(ZEND_NUM_ARGS() TSRMLS_CC, "za|b", &value, &array, &strict) == FAILURE) {
		return;
	}

	if (strict) {
		is_equal_func = is_identical_function;
	}

	zend_hash_internal_pointer_reset_ex(Z_ARRVAL_P(array), &pos);
	while (zend_hash_get_current_data_ex(Z_ARRVAL_P(array), (void **)&entry, &pos) == SUCCESS) {
		is_equal_func(&res, value, *entry TSRMLS_CC);
		if (Z_LVAL(res)) {
			if (behavior == 0) {
				RETURN_TRUE;
			} else {
				zend_hash_get_current_key_zval_ex(Z_ARRVAL_P(array), return_value, &pos);
				return;
			}
		}
		zend_hash_move_forward_ex(Z_ARRVAL_P(array), &pos);
	}

	RETURN_FALSE;
}
/* }}} */

/* {{{ proto bool in_array(mixed needle, array haystack [, bool strict])
   Checks if the given value exists in the array */
PHP_FUNCTION(in_array)
{
	php_search_array(INTERNAL_FUNCTION_PARAM_PASSTHRU, 0);
}
/* }}} */
```

php-5.6.40/Zend/zend_hash.c

```c
ZEND_API int zend_hash_move_forward_ex(HashTable *ht, HashPosition *pos)
{
  HashPosition *current = pos ? pos : &ht->pInternalPointer;

  IS_CONSISTENT(ht);

  if (*current) {
	  *current = (*current)->pListNext;
	  return SUCCESS;
  } else
	  return FAILURE;
}
```

リンクリストっぽくたどっていることがわかる。

## PHP7のin_array実装

php-7.4.14/etc/standard/array.c

```c
/* void php_search_array(INTERNAL_FUNCTION_PARAMETERS, int behavior)
 * 0 = return boolean
 * 1 = return key
 */
static inline void php_search_array(INTERNAL_FUNCTION_PARAMETERS, int behavior) /* {{{ */
{
	zval *value,				/* value to check for */
		 *array,				/* array to check in */
		 *entry;				/* pointer to array entry */
	zend_ulong num_idx;
	zend_string *str_idx;
	zend_bool strict = 0;		/* strict comparison or not */

	ZEND_PARSE_PARAMETERS_START(2, 3)
		Z_PARAM_ZVAL(value)
		Z_PARAM_ARRAY(array)
		Z_PARAM_OPTIONAL
		Z_PARAM_BOOL(strict)
	ZEND_PARSE_PARAMETERS_END();

	if (strict) {
		if (Z_TYPE_P(value) == IS_LONG) {
			ZEND_HASH_FOREACH_KEY_VAL_IND(Z_ARRVAL_P(array), num_idx, str_idx, entry) {
				ZVAL_DEREF(entry);
				if (Z_TYPE_P(entry) == IS_LONG && Z_LVAL_P(entry) == Z_LVAL_P(value)) {
					if (behavior == 0) {
						RETURN_TRUE;
					} else {
						if (str_idx) {
							RETVAL_STR_COPY(str_idx);
						} else {
							RETVAL_LONG(num_idx);
						}
						return;
					}
				}
			} ZEND_HASH_FOREACH_END();
		} else {
			ZEND_HASH_FOREACH_KEY_VAL_IND(Z_ARRVAL_P(array), num_idx, str_idx, entry) {
				ZVAL_DEREF(entry);
				if (fast_is_identical_function(value, entry)) {
					if (behavior == 0) {
						RETURN_TRUE;
					} else {
						if (str_idx) {
							RETVAL_STR_COPY(str_idx);
						} else {
							RETVAL_LONG(num_idx);
						}
						return;
					}
				}
			} ZEND_HASH_FOREACH_END();
		}
	} else {
		if (Z_TYPE_P(value) == IS_LONG) {
			ZEND_HASH_FOREACH_KEY_VAL_IND(Z_ARRVAL_P(array), num_idx, str_idx, entry) {
				if (fast_equal_check_long(value, entry)) {
					if (behavior == 0) {
						RETURN_TRUE;
					} else {
						if (str_idx) {
							RETVAL_STR_COPY(str_idx);
						} else {
							RETVAL_LONG(num_idx);
						}
						return;
					}
				}
			} ZEND_HASH_FOREACH_END();
		} else if (Z_TYPE_P(value) == IS_STRING) {
			ZEND_HASH_FOREACH_KEY_VAL_IND(Z_ARRVAL_P(array), num_idx, str_idx, entry) {
				if (fast_equal_check_string(value, entry)) {
					if (behavior == 0) {
						RETURN_TRUE;
					} else {
						if (str_idx) {
							RETVAL_STR_COPY(str_idx);
						} else {
							RETVAL_LONG(num_idx);
						}
						return;
					}
				}
			} ZEND_HASH_FOREACH_END();
		} else {
			ZEND_HASH_FOREACH_KEY_VAL_IND(Z_ARRVAL_P(array), num_idx, str_idx, entry) {
				if (fast_equal_check_function(value, entry)) {
					if (behavior == 0) {
						RETURN_TRUE;
					} else {
						if (str_idx) {
							RETVAL_STR_COPY(str_idx);
						} else {
							RETVAL_LONG(num_idx);
						}
						return;
					}
				}
			} ZEND_HASH_FOREACH_END();
 		}
	}

	RETURN_FALSE;
}
/* }}} */

/* {{{ proto bool in_array(mixed needle, array haystack [, bool strict])
   Checks if the given value exists in the array */
PHP_FUNCTION(in_array)
{
	php_search_array(INTERNAL_FUNCTION_PARAM_PASSTHRU, 0);
}
/* }}} */
```

php-7.4.14/Zend/zend_hash.h

```c
#define ZEND_HASH_FOREACH_KEY_VAL_IND(ht, _h, _key, _val) \
    ZEND_HASH_FOREACH(ht, 1); \
    _h = _p->h; \
    _key = _p->key; \
    _val = _z;
```

php-7.4.14/Zend/zend_hash.h

```c
#define ZEND_HASH_FOREACH(_ht, indirect) do { \
        HashTable *__ht = (_ht); \
        Bucket *_p = __ht->arData; \
        Bucket *_end = _p + __ht->nNumUsed; \
        for (; _p != _end; _p++) { \
            zval *_z = &_p->val; \
            if (indirect && Z_TYPE_P(_z) == IS_INDIRECT) { \
                _z = Z_INDIRECT_P(_z); \
            } \
            if (UNEXPECTED(Z_TYPE_P(_z) == IS_UNDEF)) continue;
```

こちらはいわゆる普通の配列っぽい処理になっていることがわかる。


## 比較実験

リンクリストのようにポインタを辿るのと、配列のようにポインタをずらすのとでどの程度パフォーマンスに差が出るのかに注目して比較してみる。

```c
#include<stdio.h>
#include<stdlib.h>
#include<time.h>

#define N 10000
#define TRIAL 10000

//#define N 10
//#define TRIAL 1

typedef struct Cell {
    int value;
    struct Cell *next;
} Cell;

Cell *make_cell(int i) {
    Cell *c = malloc(sizeof(Cell));
    c->value = i;
    c->next = NULL;
    return c;
}

int main(void) {
    Cell *cells[N];

    int v = 1;
    for (int i=0; i<N; i++) {
        cells[i] = make_cell(v);
        v *= -1;
    }

    for (int i=0; i<N-1; i++) {
        cells[i]->next = cells[i+1];
    }


    {
        long start = clock();
        for (int j=0; j<TRIAL; j++) {
            int sum = 0;
            Cell **ptr = cells;
            do {
                sum += (*ptr)->value;
                ptr++;
            } while (ptr-cells<N);
            //printf("%d\n", sum);
        }
        printf("%f s\n", (double)(clock() - start)/CLOCKS_PER_SEC);
    }

    {
        long start = clock();
        for (int j=0; j<TRIAL ; j++) {
            int sum = 0;
            Cell *cur = cells[0];
            do {
                sum += cur->value;
                cur = cur->next;
            } while (cur != NULL);
            //printf("%d\n", sum);
        }
        printf("%f s\n", (double)(clock() - start)/CLOCKS_PER_SEC);
    }

    return 0;
}
```


結果は

```
> gcc -O0 array_vs_list.c && ./a.out                                                                                                                                          
0.157255 s
0.244820 s
```

2倍とまではいかないものの、配列のようにポインタをずらす方が速いことがわかる。

## まとめ

in_arrayを起点としてPHP5とPHP7の実装を確認してみた。
PHP7の方は、連想配列が普通の配列のような実装になっており、その差がin_arrayの性能差として現れている。

しかし、それだけではまだ説明できない性能差もあり、他にも性能改善施策が施されていると思われる。


## おまけ

zend_hash_get_current_data_ex の実装を見てみると、

php-5.6.40/Zend/zend_hash.c

```c
ZEND_API int zend_hash_get_current_data_ex(HashTable *ht, void **pData, HashPosition *pos)
{
    Bucket *p;

    p = pos ? (*pos) : ht->pInternalPointer;

    IS_CONSISTENT(ht);

    if (p) {
        *pData = p->pData;
        return SUCCESS;
    } else {
        return FAILURE;
    }
}

```

php-7.4.14/Zend/zend_hash.c

```c
static zend_always_inline HashPosition _zend_hash_get_valid_pos(const HashTable *ht, HashPosition pos)
{
    while (pos < ht->nNumUsed && Z_ISUNDEF(ht->arData[pos].val)) {
        pos++;
    }
    return pos;
}

...
...
...

ZEND_API zval* ZEND_FASTCALL zend_hash_get_current_data_ex(HashTable *ht, HashPosition *pos)
{
    uint32_t idx;
    Bucket *p;

    IS_CONSISTENT(ht);
    idx = _zend_hash_get_valid_pos(ht, *pos);
    if (idx < ht->nNumUsed) {
        p = ht->arData + idx;
        return &p->val;
    } else {
        return NULL;
    }
}
```

PHP7の方は普通の配列のような実装になっているため、unsetで歯抜けになる。
その部分をスキップする処理が入っている。
