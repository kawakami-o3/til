# 任意のテーブルに対して sql.Rows.Scan をかける

※production環境では使ってはならない



カラムが null のときがあり、素朴にScanすると失敗する。
こういった場合に備えて NullString などの構造体が用意されている。





