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



## 比較実験


