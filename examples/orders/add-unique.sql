-- Prevent reuse of a payment transaction number.
ALTER TABLE orders
  ADD UNIQUE INDEX uk_payment_no (payment_no);
