ALTER TABLE orders
  ADD UNIQUE INDEX uk_merchant_payment (merchant_id, payment_no);
