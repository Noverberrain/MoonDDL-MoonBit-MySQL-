CREATE UNIQUE INDEX uk_merchant_payment
  ON orders (merchant_id, payment_no);
