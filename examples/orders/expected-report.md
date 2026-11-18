# MoonDDL 迁移预检

待核查 1 项，未分析 0 项。

### 待核查 · examples/orders/add-unique.sql:2

orders.payment\_no 新增唯一索引。请核对历史数据中的重复非空值。

```sql
SELECT `payment_no`, COUNT(*) AS duplicate_count
FROM `orders`
WHERE `payment_no` IS NOT NULL
GROUP BY `payment_no`
HAVING COUNT(*) > 1;
```
