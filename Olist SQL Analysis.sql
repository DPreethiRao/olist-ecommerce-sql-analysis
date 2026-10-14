-- Tables used: olist_orders_dataset, olist_order_items_dataset, olist_order_payments_dataset,olist_order_reviews_dataset, olist_customers_dataset, olist_products_dataset, product_category_name_translation


-- CLEANING 
UPDATE olist_orders_dataset SET order_approved_at=NULL WHERE order_approved_at='';
UPDATE olist_orders_dataset SET order_delivered_carrier_date=NULL WHERE order_delivered_carrier_date='';
UPDATE olist_orders_dataset SET order_delivered_customer_date=NULL WHERE order_delivered_customer_date='';


SELECT
  SUM(order_delivered_customer_date IS NULL) AS null_delivery,
  SUM(order_delivered_customer_date = '') AS empty_delivery
FROM olist_orders_dataset;

-- Q1: Data quality - order statuses and missing delivery dates
SELECT order_status, COUNT(*) AS orders,
       SUM(order_delivered_customer_date IS NULL) AS missing_delivery_date
FROM olist_orders_dataset GROUP BY order_status ORDER BY orders DESC;


-- Q2: Monthly revenue and orders (delivered orders; revenue = item price, freight shown separately)
SELECT substr(o.order_purchase_timestamp,1,7) AS month, COUNT(DISTINCT o.order_id) AS orders,
       ROUND(SUM(i.price),0) AS revenue, ROUND(SUM(i.freight_value),0) AS freight,
       ROUND(SUM(i.price)/COUNT(DISTINCT o.order_id),2) AS avg_order_value
FROM olist_orders_dataset o JOIN olist_order_items_dataset i ON i.order_id=o.order_id
WHERE o.order_status='delivered' GROUP BY month ORDER BY month;

-- Q3: Month-over-month revenue growth (window function LAG)
WITH m AS (
  SELECT substr(o.order_purchase_timestamp,1,7) AS month, SUM(i.price) AS revenue
  FROM olist_orders_dataset o JOIN olist_order_items_dataset i ON i.order_id=o.order_id
  WHERE o.order_status='delivered' GROUP BY month)
SELECT month, ROUND(revenue,0) AS revenue,
       ROUND(100.0*(revenue-LAG(revenue) OVER (ORDER BY month))/LAG(revenue) OVER (ORDER BY month),1) AS mom_growth_pct
FROM m ORDER BY month;


-- Q4: Top 10 product categories by revenue (English names, share of total)
SELECT COALESCE(t.product_category_name_english, p.product_category_name, 'unknown') AS category,
       COUNT(DISTINCT i.order_id) AS orders, ROUND(SUM(i.price),0) AS revenue,
       ROUND(100.0*SUM(i.price)/SUM(SUM(i.price)) OVER (),1) AS pct_of_revenue,
       ROUND(AVG(i.price),2) AS avg_price
FROM olist_order_items_dataset i
JOIN olist_orders_dataset o ON o.order_id=i.order_id AND o.order_status='delivered'
LEFT JOIN olist_products_dataset p ON p.product_id=i.product_id
LEFT JOIN product_category_name_translation t ON t.product_category_name=p.product_category_name
GROUP BY category ORDER BY revenue DESC LIMIT 10;


-- Q5: Revenue by customer state - how concentrated is the market?
SELECT c.customer_state, COUNT(DISTINCT c.customer_unique_id) AS customers,
       ROUND(SUM(i.price),0) AS revenue,
       ROUND(100.0*SUM(i.price)/SUM(SUM(i.price)) OVER (),1) AS pct_of_revenue,
       ROUND(SUM(i.price)/COUNT(DISTINCT c.customer_unique_id),2) AS revenue_per_customer
FROM olist_orders_dataset o
JOIN olist_customers_dataset c ON c.customer_id=o.customer_id
JOIN olist_order_items_dataset i ON i.order_id=o.order_id
WHERE o.order_status='delivered' GROUP BY c.customer_state ORDER BY revenue DESC LIMIT 10;


-- Q6: Repeat purchase rate. IMPORTANT: customer_id is unique PER ORDER; use customer_unique_id for people.
WITH per_cust AS (
  SELECT c.customer_unique_id, COUNT(DISTINCT o.order_id) AS orders
  FROM olist_orders_dataset o JOIN olist_customers_dataset c ON c.customer_id=o.customer_id
  WHERE o.order_status='delivered' GROUP BY c.customer_unique_id)
SELECT CASE WHEN orders>=3 THEN '3+' ELSE CAST(orders AS TEXT) END AS orders_placed,
       COUNT(*) AS customers, ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),1) AS pct_of_customers
FROM per_cust GROUP BY orders_placed ORDER BY orders_placed;


-- Q7: Customer value segments (recency + spend quartiles; frequency is mostly 1 so it is split repeat vs one-time)
WITH cust AS (
  SELECT c.customer_unique_id, MAX(o.order_purchase_timestamp) AS last_order,
         COUNT(DISTINCT o.order_id) AS orders, SUM(p.payment_value) AS spend
  FROM olist_orders_dataset o
  JOIN olist_customers_dataset c ON c.customer_id=o.customer_id
  JOIN olist_order_payments_dataset p ON p.order_id=o.order_id
  WHERE o.order_status='delivered' GROUP BY c.customer_unique_id),
scored AS (
  SELECT *, NTILE(4) OVER (ORDER BY last_order) AS r, NTILE(4) OVER (ORDER BY spend) AS m FROM cust),
seg AS (
  SELECT *, CASE WHEN orders>=2 AND m>=3 THEN 'Loyal high-value'
                 WHEN orders>=2 THEN 'Repeat buyers'
                 WHEN m=4 AND r>=3 THEN 'Recent big spenders (one-time)'
                 WHEN m=4 THEN 'Lapsed big spenders (one-time)'
                 ELSE 'Other one-time buyers' END AS segment FROM scored)
SELECT segment, COUNT(*) AS customers, ROUND(AVG(spend),0) AS avg_spend, ROUND(SUM(spend),0) AS total_spend,
       ROUND(100.0*SUM(spend)/SUM(SUM(spend)) OVER (),1) AS pct_of_revenue
FROM seg GROUP BY segment ORDER BY total_spend DESC;


-- Q8: DELIVERY PERFORMANCE vs CUSTOMER SATISFACTION (the headline analysis)
WITH rev AS (SELECT order_id, AVG(review_score) AS score FROM olist_order_reviews_dataset GROUP BY order_id),
d AS (
  SELECT o.order_id, r.score,
         julianday(o.order_delivered_customer_date)-julianday(o.order_estimated_delivery_date) AS days_vs_estimate
  FROM olist_orders_dataset o JOIN rev r ON r.order_id=o.order_id
  WHERE o.order_status='delivered' AND o.order_delivered_customer_date IS NOT NULL)
SELECT CASE WHEN days_vs_estimate<=-7 THEN '1. 7+ days early'
            WHEN days_vs_estimate<=0 THEN '2. On time (0-7 days early)'
            WHEN days_vs_estimate<=7 THEN '3. Late 1-7 days'
            ELSE '4. Late 7+ days' END AS delivery_bucket,
       COUNT(*) AS orders, ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),1) AS pct_of_orders,
       ROUND(AVG(score),2) AS avg_review_score,
       ROUND(100.0*SUM(score<=2)/COUNT(*),1) AS pct_bad_reviews
FROM d GROUP BY delivery_bucket ORDER BY delivery_bucket;


-- Q9: Payment method mix
SELECT payment_type, COUNT(DISTINCT order_id) AS orders,
       ROUND(100.0*COUNT(DISTINCT order_id)/(SELECT COUNT(DISTINCT order_id) FROM olist_order_payments_dataset),1) AS pct_of_orders,
       ROUND(SUM(payment_value),0) AS total_value, ROUND(AVG(payment_value),2) AS avg_payment,
       ROUND(AVG(payment_installments),1) AS avg_installments
FROM olist_order_payments_dataset GROUP BY payment_type ORDER BY orders DESC;


-- Q10: Which states have the worst delivery delays? (joins Q5 + Q8 ideas)
SELECT c.customer_state, COUNT(*) AS orders,
       ROUND(AVG(julianday(o.order_delivered_customer_date)-julianday(o.order_purchase_timestamp)),1) AS avg_delivery_days,
       ROUND(100.0*SUM(o.order_delivered_customer_date>o.order_estimated_delivery_date)/COUNT(*),1) AS pct_late
FROM olist_orders_dataset o JOIN olist_customers_dataset c ON c.customer_id=o.customer_id
WHERE o.order_status='delivered' AND o.order_delivered_customer_date IS NOT NULL
GROUP BY c.customer_state HAVING orders>=300 ORDER BY avg_delivery_days DESC LIMIT 10;

