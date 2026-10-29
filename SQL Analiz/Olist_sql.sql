--TABLO KONTOLÜ
SELECT 'customers'   AS Tablo, COUNT(*) AS Satir FROM dbo.olist_customers_dataset
UNION ALL SELECT 'orders',       COUNT(*) FROM dbo.olist_orders_dataset
UNION ALL SELECT 'order_items',  COUNT(*) FROM dbo.olist_order_items_dataset
UNION ALL SELECT 'payments',     COUNT(*) FROM dbo.olist_order_payments_dataset
UNION ALL SELECT 'reviews',      COUNT(*) FROM dbo.olist_order_reviews_dataset
UNION ALL SELECT 'products',     COUNT(*) FROM dbo.olist_products_dataset
UNION ALL SELECT 'sellers',      COUNT(*) FROM dbo.olist_sellers_dataset
UNION ALL SELECT 'geolocation',  COUNT(*) FROM dbo.olist_geolocation_dataset
UNION ALL SELECT 'translation',  COUNT(*) FROM dbo.product_category_name_translation;

-- Ürün isimleri Portekizce bunları ingilizce halinde görmek.
DELETE FROM dbo.product_category_name_translation
WHERE column1 = N'product_category_name';

EXEC sp_rename 'dbo.product_category_name_translation.column1', 'product_category_name', 'COLUMN';
EXEC sp_rename 'dbo.product_category_name_translation.column2', 'product_category_name_english', 'COLUMN';

SELECT COUNT(*) AS Satir FROM dbo.product_category_name_translation;
SELECT TOP 5 * FROM dbo.product_category_name_translation;


-- 9 tablonun, verilerini ve null değerlerini kontrol etme.
IF OBJECT_ID('tempdb..#NullRapor') IS NOT NULL DROP TABLE #NullRapor;
CREATE TABLE #NullRapor (
    Tablo SYSNAME, Kolon SYSNAME, VeriTipi SYSNAME,
    ToplamSatir INT, NullSayisi INT, BosMetinSayisi INT
);

DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql += 
      N'INSERT INTO #NullRapor SELECT N''' + t.name + N''', N''' + c.name + N''', N''' + ty.name + N''', COUNT(*), '
    + N'SUM(CASE WHEN ' + QUOTENAME(c.name) + N' IS NULL THEN 1 ELSE 0 END), '
    + CASE WHEN ty.name IN (N'varchar', N'nvarchar', N'char', N'nchar')
           THEN N'SUM(CASE WHEN LTRIM(RTRIM(' + QUOTENAME(c.name) + N')) = N'''' THEN 1 ELSE 0 END)'
           ELSE N'0' END
    + N' FROM dbo.' + QUOTENAME(t.name) + N';' + CHAR(10)
FROM sys.tables t
JOIN sys.columns c ON c.object_id = t.object_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE t.name LIKE N'olist[_]%' OR t.name = N'product_category_name_translation';

EXEC sp_executesql @sql;

SELECT Tablo, Kolon, VeriTipi, ToplamSatir, NullSayisi, BosMetinSayisi,
       CAST(100.0 * (NullSayisi + BosMetinSayisi) / NULLIF(ToplamSatir, 0) AS DECIMAL(5,2)) AS EksikYuzde
FROM #NullRapor
WHERE NullSayisi > 0 OR BosMetinSayisi > 0
ORDER BY Tablo, Kolon;

--Orders’taki eksik tarihlerin nedeni
SELECT order_status,
       COUNT(*) AS Siparis,
       SUM(CASE WHEN order_approved_at IS NULL THEN 1 ELSE 0 END)            AS OnayTarihiYok,
       SUM(CASE WHEN order_delivered_carrier_date IS NULL THEN 1 ELSE 0 END) AS KargoTarihiYok,
       SUM(CASE WHEN order_delivered_customer_date IS NULL THEN 1 ELSE 0 END) AS TeslimTarihiYok
FROM dbo.olist_orders_dataset
GROUP BY order_status
ORDER BY Siparis DESC;

-- Ürün bilgilerinin kontrolü
SELECT p.product_category_name, COUNT(*) AS UrunSayisi
FROM dbo.olist_products_dataset p
LEFT JOIN dbo.product_category_name_translation t
       ON p.product_category_name = t.product_category_name
WHERE t.product_category_name IS NULL
GROUP BY p.product_category_name
ORDER BY UrunSayisi DESC;

SELECT TOP 10 *
FROM dbo.olist_products_dataset
WHERE product_category_name = N'bilinmiyor';

SELECT CASE WHEN product_category_name = N'bilinmiyor' THEN N'bilinmiyor' ELSE N'diger' END AS Grup,
       COUNT(*) AS Urun,
       SUM(CASE WHEN product_name_lenght = 0 THEN 1 ELSE 0 END)        AS AdUzunluguSifir,
       SUM(CASE WHEN product_description_lenght = 0 THEN 1 ELSE 0 END) AS AciklamaSifir,
       SUM(CASE WHEN product_photos_qty = 0 THEN 1 ELSE 0 END)         AS FotoSifir
FROM dbo.olist_products_dataset
GROUP BY CASE WHEN product_category_name = N'bilinmiyor' THEN N'bilinmiyor' ELSE N'diger' END;

-- Ürün View Oluşturma
USE [Brazilian_E-Commerce_Public];
GO

CREATE OR ALTER VIEW dbo.vw_products_clean AS
SELECT
    p.product_id,
    CASE
        WHEN p.product_category_name = N'bilinmiyor' THEN N'unknown'
        ELSE COALESCE(
                t.product_category_name_english,
                CASE p.product_category_name
                     WHEN N'portateis_cozinha_e_preparadores_de_alimentos' THEN N'portable_kitchen_food_preparers'
                     WHEN N'pc_gamer' THEN N'pc_gamer'
                END,
                p.product_category_name)
    END                                         AS category_english,
    NULLIF(p.product_name_lenght, 0)            AS name_length,
    NULLIF(p.product_description_lenght, 0)     AS description_length,
    NULLIF(p.product_photos_qty, 0)             AS photos_qty,
    p.product_weight_g,
    p.product_length_cm,
    p.product_height_cm,
    p.product_width_cm
FROM dbo.olist_products_dataset p
LEFT JOIN dbo.product_category_name_translation t
       ON t.product_category_name = p.product_category_name;
GO

SELECT COUNT(*) AS Urun,
       SUM(CASE WHEN category_english IS NULL THEN 1 ELSE 0 END) AS KategoriNull,
       SUM(CASE WHEN category_english = N'unknown' THEN 1 ELSE 0 END) AS KategoriUnknown,
       SUM(CASE WHEN photos_qty IS NULL THEN 1 ELSE 0 END) AS FotoNull
FROM dbo.vw_products_clean;

--Temiz sipariş view’i (teslimat gecikmesi dahil) oluşturma
CREATE OR ALTER VIEW dbo.vw_orders_clean AS
SELECT
    o.order_id,
    o.customer_id,
    o.order_status,
    o.order_purchase_timestamp       AS purchase_ts,
    o.order_approved_at              AS approved_ts,
    o.order_delivered_carrier_date   AS carrier_ts,
    o.order_delivered_customer_date  AS delivered_ts,
    o.order_estimated_delivery_date  AS estimated_ts,
    DATEFROMPARTS(YEAR(o.order_purchase_timestamp),
                  MONTH(o.order_purchase_timestamp), 1) AS purchase_month,
    d.flag AS is_delivered,
    CASE WHEN d.flag = 1
         THEN DATEDIFF(DAY, o.order_purchase_timestamp, o.order_delivered_customer_date)
    END AS delivery_days,
    CASE WHEN d.flag = 1
         THEN DATEDIFF(DAY, CAST(o.order_estimated_delivery_date AS date),
                            CAST(o.order_delivered_customer_date AS date))
    END AS delay_days,
    CASE WHEN d.flag = 1
         THEN CASE WHEN CAST(o.order_delivered_customer_date AS date)
                      > CAST(o.order_estimated_delivery_date AS date) THEN 1 ELSE 0 END
    END AS is_late
FROM dbo.olist_orders_dataset o
CROSS APPLY (
    SELECT CASE WHEN o.order_status = N'delivered'
                 AND o.order_delivered_customer_date IS NOT NULL
                THEN 1 ELSE 0 END AS flag
) d;
GO

SELECT COUNT(*)                                       AS Siparis,
       SUM(is_delivered)                              AS TeslimEdilen,
       COUNT(is_late)                                 AS GecikmeHesaplanan,
       SUM(is_late)                                   AS Geciken,
       CAST(100.0 * SUM(is_late) / NULLIF(COUNT(is_late), 0) AS DECIMAL(5,2)) AS GecikmeYuzdesi
FROM dbo.vw_orders_clean;



-- Yorum ve ödeme tablolarında tekrar var mı?
SELECT N'reviews'     AS Tablo, COUNT(*) AS Satir, COUNT(DISTINCT order_id) AS BenzersizSiparis
FROM dbo.olist_order_reviews_dataset
UNION ALL
SELECT N'payments',   COUNT(*), COUNT(DISTINCT order_id)
FROM dbo.olist_order_payments_dataset
UNION ALL
SELECT N'order_items', COUNT(*), COUNT(DISTINCT order_id)
FROM dbo.olist_order_items_dataset;


-- Sipariş View oluşturma.(yorum ve ödeme tekrarını düzelterek)
CREATE OR ALTER VIEW dbo.vw_order_reviews AS
SELECT
    order_id,
    review_id,
    review_score,
    review_creation_date    AS review_created_ts,
    review_answer_timestamp AS review_answered_ts,
    NULLIF(LTRIM(RTRIM(review_comment_title)),   N'') AS comment_title,
    NULLIF(LTRIM(RTRIM(review_comment_message)), N'') AS comment_message,
    review_count
FROM (
    SELECT r.*,
           ROW_NUMBER() OVER (PARTITION BY r.order_id
                              ORDER BY r.review_creation_date DESC,
                                       r.review_answer_timestamp DESC,
                                       r.review_id) AS rn,
           COUNT(*) OVER (PARTITION BY r.order_id)   AS review_count
    FROM dbo.olist_order_reviews_dataset r
) x
WHERE rn = 1;
GO

SELECT COUNT(*)                 AS Satir,
       COUNT(DISTINCT order_id) AS BenzersizSiparis,
       SUM(CASE WHEN review_count > 1 THEN 1 ELSE 0 END) AS BirdenFazlaYorumluSiparis
FROM dbo.vw_order_reviews;

--Tek satırlık sipariş analiz view’i oluşturma

CREATE OR ALTER VIEW dbo.vw_order_analysis AS
SELECT
    o.order_id,
    o.customer_id,
    c.customer_unique_id,
    c.customer_state,
    o.order_status,
    o.purchase_ts,
    o.purchase_month,
    o.is_delivered,
    o.delivery_days,
    o.delay_days,
    o.is_late,
    i.item_count,
    i.item_revenue,
    i.freight_total,
    p.payment_count,
    p.payment_total,
    r.review_score,
    r.review_count,
    r.comment_message
FROM dbo.vw_orders_clean o
LEFT JOIN dbo.olist_customers_dataset c
       ON c.customer_id = o.customer_id
LEFT JOIN (
    SELECT order_id,
           COUNT(*)                                   AS item_count,
           CAST(SUM(price) AS DECIMAL(12,2))          AS item_revenue,
           CAST(SUM(freight_value) AS DECIMAL(12,2))  AS freight_total
    FROM dbo.olist_order_items_dataset
    GROUP BY order_id
) i ON i.order_id = o.order_id
LEFT JOIN (
    SELECT order_id,
           COUNT(*)                                   AS payment_count,
           CAST(SUM(payment_value) AS DECIMAL(12,2))  AS payment_total
    FROM dbo.olist_order_payments_dataset
    GROUP BY order_id
) p ON p.order_id = o.order_id
LEFT JOIN dbo.vw_order_reviews r
       ON r.order_id = o.order_id;
GO

SELECT COUNT(*)                  AS Satir,
       COUNT(DISTINCT order_id)  AS BenzersizSiparis,
       COUNT(item_count)         AS KalemiOlan,
       COUNT(payment_total)      AS OdemesiOlan,
       COUNT(review_score)       AS YorumuOlan,
       CAST(SUM(item_revenue) AS DECIMAL(14,2)) AS UrunCirosu_View,
       (SELECT CAST(SUM(price) AS DECIMAL(14,2))
        FROM dbo.olist_order_items_dataset)     AS UrunCirosu_Ham
FROM dbo.vw_order_analysis;

--- Analysis view içinde ciro 100 kat fazla gösteriliyor. Veri aktarımında ondalıklı yerine tam sayı olarak aktarılmış.

SELECT N'price'         AS Kolon, MIN(price) AS Min, AVG(price) AS Ort, MAX(price) AS Max
FROM dbo.olist_order_items_dataset
UNION ALL
SELECT N'freight_value', MIN(freight_value), AVG(freight_value), MAX(freight_value)
FROM dbo.olist_order_items_dataset
UNION ALL
SELECT N'payment_value', MIN(payment_value), AVG(payment_value), MAX(payment_value)
FROM dbo.olist_order_payments_dataset;

SELECT TOP 10 order_id, price, freight_value
FROM dbo.olist_order_items_dataset;

CREATE OR ALTER VIEW dbo.vw_order_analysis AS
SELECT
    o.order_id,
    o.customer_id,
    c.customer_unique_id,
    c.customer_state,
    o.order_status,
    o.purchase_ts,
    o.purchase_month,
    o.is_delivered,
    o.delivery_days,
    o.delay_days,
    o.is_late,
    i.item_count,
    i.item_revenue,
    i.freight_total,
    p.payment_count,
    p.payment_total,
    r.review_score,
    r.review_count,
    r.comment_message
FROM dbo.vw_orders_clean o
LEFT JOIN dbo.olist_customers_dataset c
       ON c.customer_id = o.customer_id
LEFT JOIN (
    SELECT order_id,
           COUNT(*)                                          AS item_count,
           CAST(SUM(price) / 100.0 AS DECIMAL(12,2))         AS item_revenue,
           CAST(SUM(freight_value) / 100.0 AS DECIMAL(12,2)) AS freight_total
    FROM dbo.olist_order_items_dataset
    GROUP BY order_id
) i ON i.order_id = o.order_id
LEFT JOIN (
    SELECT order_id,
           COUNT(*)                                          AS payment_count,
           CAST(SUM(payment_value) / 100.0 AS DECIMAL(12,2)) AS payment_total
    FROM dbo.olist_order_payments_dataset
    GROUP BY order_id
) p ON p.order_id = o.order_id
LEFT JOIN dbo.vw_order_reviews r
       ON r.order_id = o.order_id;
GO

SELECT CAST(SUM(item_revenue)  AS DECIMAL(14,2)) AS UrunCirosu,
       CAST(SUM(freight_total) AS DECIMAL(14,2)) AS KargoToplam,
       CAST(SUM(payment_total) AS DECIMAL(14,2)) AS OdemeToplam,
       CAST(AVG(item_revenue)  AS DECIMAL(10,2)) AS OrtSiparisUrunTutari
FROM dbo.vw_order_analysis;
------------------------------------------ Karşılan sorunların tespiti ve analizi------------------------------------------

-- Siparişlerdeki gecikme müşteri puanını etkiliyor mu?
SELECT g.Grup,
       COUNT(*) AS Siparis,
       CAST(AVG(CAST(a.review_score AS FLOAT)) AS DECIMAL(4,2)) AS OrtPuan,
       CAST(100.0 * SUM(CASE WHEN a.review_score <= 2 THEN 1 ELSE 0 END) / COUNT(*)
            AS DECIMAL(5,2)) AS DusukPuanYuzdesi
FROM dbo.vw_order_analysis a
CROSS APPLY (
    SELECT CASE WHEN a.delay_days <= 0               THEN N'1) Zamanında / erken'
                WHEN a.delay_days BETWEEN 1 AND 3    THEN N'2) 1-3 gün geç'
                WHEN a.delay_days BETWEEN 4 AND 7    THEN N'3) 4-7 gün geç'
                ELSE                                      N'4) 8+ gün geç'
           END AS Grup
) g
WHERE a.is_delivered = 1
  AND a.review_score IS NOT NULL
GROUP BY g.Grup
ORDER BY g.Grup;

-- Gecikme nerede yoğunlaşıyor ve düşük puanın ne kadarı gecikmeden?

-- A) Eyalet bazında gecikme (en az 500 siparişi olan eyaletler)
SELECT TOP 10
       customer_state,
       COUNT(*) AS Siparis,
       CAST(100.0 * SUM(is_late) / COUNT(*) AS DECIMAL(5,2))        AS GecikmeYuzdesi,
       CAST(AVG(CAST(delivery_days AS FLOAT)) AS DECIMAL(5,1))      AS OrtTeslimGunu
FROM dbo.vw_order_analysis
WHERE is_delivered = 1
GROUP BY customer_state
HAVING COUNT(*) >= 500
ORDER BY GecikmeYuzdesi DESC;

-- B) Düşük puanlı (1-2 yıldız) siparişlerin ne kadarı geç teslim?
SELECT COUNT(*)                                            AS DusukPuanSiparis,
       SUM(CASE WHEN is_late = 1 THEN 1 ELSE 0 END)        AS BunlardanGecTeslim,
       CAST(100.0 * SUM(CASE WHEN is_late = 1 THEN 1 ELSE 0 END) / COUNT(*)
            AS DECIMAL(5,2))                               AS GecinPayiYuzde
FROM dbo.vw_order_analysis
WHERE is_delivered = 1
  AND review_score <= 2;


--Aylık trend ve önceki ay karşılaştırması
WITH Aylik AS (
    SELECT purchase_month                                           AS Ay,
           COUNT(*)                                                 AS Siparis,
           CAST(SUM(CASE WHEN order_status NOT IN (N'canceled', N'unavailable')
                         THEN item_revenue END) AS DECIMAL(14,2))  AS Ciro,
           CAST(100.0 * SUM(is_late) / NULLIF(COUNT(is_late), 0)
                AS DECIMAL(5,2))                                    AS GecikmeYuzdesi,
           CAST(AVG(CAST(review_score AS FLOAT)) AS DECIMAL(4,2))   AS OrtPuan
    FROM dbo.vw_order_analysis
    GROUP BY purchase_month
),
Karsilastirma AS (
    SELECT *,
           LAG(Ciro)    OVER (ORDER BY Ay) AS OncekiCiro,
           LAG(Siparis) OVER (ORDER BY Ay) AS OncekiSiparis
    FROM Aylik
)
SELECT Ay, Siparis, Ciro, GecikmeYuzdesi, OrtPuan,
       CASE WHEN OncekiSiparis >= 100
            THEN CAST(100.0 * (Ciro - OncekiCiro) / NULLIF(OncekiCiro, 0) AS DECIMAL(8,2))
       END AS CiroDegisimOncekiAy_Yuzde
FROM Karsilastirma
ORDER BY Ay;

-- Düşük puanın diğer sebepleri
WITH SiparisKategori AS (
    SELECT i.order_id, MIN(p.category_english) AS Kategori
    FROM dbo.olist_order_items_dataset i
    JOIN dbo.vw_products_clean p ON p.product_id = i.product_id
    GROUP BY i.order_id
    HAVING COUNT(DISTINCT p.category_english) = 1
)
SELECT TOP 10
       sk.Kategori,
       COUNT(*) AS Siparis,
       CAST(AVG(CAST(a.review_score AS FLOAT)) AS DECIMAL(4,2)) AS OrtPuan,
       CAST(100.0 * SUM(CASE WHEN a.review_score <= 2 THEN 1 ELSE 0 END) / COUNT(*)
            AS DECIMAL(5,2)) AS DusukPuanYuzdesi
FROM SiparisKategori sk
JOIN dbo.vw_order_analysis a ON a.order_id = sk.order_id
WHERE a.is_delivered = 1
  AND a.is_late = 0
  AND a.review_score IS NOT NULL
GROUP BY sk.Kategori
HAVING COUNT(*) >= 300
ORDER BY DusukPuanYuzdesi DESC;

-- Order sipariş kalemleri
CREATE OR ALTER VIEW dbo.vw_order_items_clean AS
SELECT
    order_id,
    order_item_id,
    product_id,
    seller_id,
    CAST(price / 100.0 AS DECIMAL(12,2))         AS price,
    CAST(freight_value / 100.0 AS DECIMAL(12,2)) AS freight_value
FROM dbo.olist_order_items_dataset;

SELECT COUNT(*) AS Satir, CAST(SUM(price) AS DECIMAL(14,2)) AS ToplamGelir
FROM dbo.vw_order_items_clean;

SELECT
    (SELECT CAST(SUM(price) AS DECIMAL(14,2)) FROM dbo.vw_order_items_clean) AS KalemToplam,
    (SELECT CAST(SUM(item_revenue) AS DECIMAL(14,2)) FROM dbo.vw_order_analysis) AS SiparisToplam;

--Order Kategori analizi
CREATE OR ALTER VIEW dbo.vw_order_category AS
SELECT
    i.order_id,
    MIN(p.category_english) AS category_english
FROM dbo.olist_order_items_dataset i
JOIN dbo.vw_products_clean p ON p.product_id = i.product_id
GROUP BY i.order_id
HAVING COUNT(DISTINCT p.category_english) = 1;

SELECT COUNT(*) AS TekKategoriliSiparis,
       SUM(CASE WHEN category_english = 'office_furniture' THEN 1 ELSE 0 END) AS OfficeFurniture
FROM dbo.vw_order_category;

-- Sipariş Özeti: Satıcılar ve Kategoriler 
WITH SiparisOzet AS (
    SELECT i.order_id,
           COUNT(DISTINCT p.category_english) AS KategoriSayisi,
           COUNT(DISTINCT i.seller_id)        AS SaticiSayisi
    FROM dbo.olist_order_items_dataset i
    JOIN dbo.vw_products_clean p ON p.product_id = i.product_id
    GROUP BY i.order_id
)
SELECT
    CASE WHEN s.KategoriSayisi = 1 THEN '1 kategori' ELSE '2+ kategori' END AS Kategori,
    CASE WHEN s.SaticiSayisi   = 1 THEN '1 satici'   ELSE '2+ satici'   END AS Satici,
    COUNT(*) AS Siparis,
    CAST(100.0 * SUM(CASE WHEN a.review_score <= 2 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS DusukPuanYuzdesi
FROM SiparisOzet s
JOIN dbo.vw_order_analysis a ON a.order_id = s.order_id
WHERE a.is_delivered = 1 AND a.is_late = 0 AND a.review_score IS NOT NULL
GROUP BY
    CASE WHEN s.KategoriSayisi = 1 THEN '1 kategori' ELSE '2+ kategori' END,
    CASE WHEN s.SaticiSayisi   = 1 THEN '1 satici'   ELSE '2+ satici'   END
ORDER BY Kategori, Satici;

SELECT
    CASE WHEN x.SaticiSayisi = 1 THEN '1 satici' ELSE '2+ satici' END AS Satici,
    COUNT(*) AS Siparis,
    CAST(100.0 * SUM(CASE WHEN a.review_score <= 2 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS DusukPuanYuzdesi
FROM (
    SELECT i.order_id, COUNT(DISTINCT i.seller_id) AS SaticiSayisi
    FROM dbo.olist_order_items_dataset i
    WHERE i.order_id IN (SELECT order_id FROM dbo.vw_order_category WHERE category_english = 'office_furniture')
    GROUP BY i.order_id
) x
JOIN dbo.vw_order_analysis a ON a.order_id = x.order_id
WHERE a.is_delivered = 1 AND a.is_late = 0 AND a.review_score IS NOT NULL
GROUP BY CASE WHEN x.SaticiSayisi = 1 THEN '1 satici' ELSE '2+ satici' END;

-- Müşteri Yorumları (Not: Müşteriler portekizce konuştuğu için anlamlarına çeviriden bakıldı.)

SELECT TOP 40 a.review_score, a.comment_message
FROM dbo.vw_order_analysis a
JOIN dbo.vw_order_category c ON c.order_id = a.order_id
WHERE c.category_english = 'office_furniture'
  AND a.is_delivered = 1
  AND a.is_late = 0
  AND a.review_score <= 2
  AND a.comment_message IS NOT NULL
ORDER BY a.order_id;

-- Kalem Sayısı(sipariş) ile Düşük puan ilişkisi
SELECT
    CASE WHEN a.item_count = 1 THEN '1 kalem'
         WHEN a.item_count = 2 THEN '2 kalem'
         ELSE '3+ kalem' END AS Kalem,
    COUNT(*) AS Siparis,
    CAST(100.0 * SUM(CASE WHEN a.review_score <= 2 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS DusukPuanYuzdesi
FROM dbo.vw_order_analysis a
JOIN dbo.vw_order_category c ON c.order_id = a.order_id
WHERE c.category_english = 'office_furniture'
  AND a.is_delivered = 1
  AND a.is_late = 0
  AND a.review_score IS NOT NULL
GROUP BY CASE WHEN a.item_count = 1 THEN '1 kalem'
              WHEN a.item_count = 2 THEN '2 kalem'
              ELSE '3+ kalem' END
ORDER BY Kalem;

--Kontrol, kalem sayısı etkisi her yerde var mı?
SELECT
    CASE WHEN item_count = 1 THEN '1 kalem'
         WHEN item_count = 2 THEN '2 kalem'
         ELSE '3+ kalem' END AS Kalem,
    COUNT(*) AS Siparis,
    CAST(100.0 * SUM(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS DusukPuanYuzdesi
FROM dbo.vw_order_analysis
WHERE is_delivered = 1
  AND is_late = 0
  AND review_score IS NOT NULL
  AND item_count >= 1
GROUP BY CASE WHEN item_count = 1 THEN '1 kalem'
              WHEN item_count = 2 THEN '2 kalem'
              ELSE '3+ kalem' END
ORDER BY Kalem;