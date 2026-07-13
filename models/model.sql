--========================================
--Base: serving (Star Schema)
--========================================

--Objetivo
--- FactTransaction particionada por YearMonth.
--- Dedupe global por UNIQUE(TransactionId) (global).
--- Índices rowstore para atender agregações e listagem.

SET QUOTED_IDENTIFIER, ANSI_NULLS ON;
GO

CREATE DATABASE SQL_XP_ACCOUNTMANAGEMENT_PFM;
GO

USE SQL_XP_ACCOUNTMANAGEMENT_PFM;
GO

CREATE SCHEMA serving;
GO

/* ------------------------------------------------------------
DimClient:
- ClientId: surrogate key (PK)
- TradingAccount + Brand: natural key (UNIQUE)
------------------------------------------------------------ */
CREATE TABLE serving.DimClient
(
    ClientId INT NOT NULL IDENTITY(1,1) CONSTRAINT PK_DimClient PRIMARY KEY,
    TradingAccount BIGINT NOT NULL,
    Brand SMALLINT NOT NULL,
    MonthlySpendingTarget DECIMAL(18,2) NULL,
	CreatedAt DATETIME2(3) NOT NULL CONSTRAINT DF_DimClient_CreatedAt DEFAULT SYSUTCDATETIME(),
	UpdateAt DATETIME2(3) NULL,

    CONSTRAINT UQ_DimClient_TradingAccount_Brand UNIQUE (TradingAccount, Brand)
);
GO

/* Lookup rápido do ClientId por TradingAccount+Brand */
CREATE INDEX IX_DimClient_Lookup_TradingAccount_Brand
ON serving.DimClient (TradingAccount, Brand)
INCLUDE (ClientId, MonthlySpendingTarget);
GO


CREATE TABLE serving.DimCategory
(
    CategoryId INT NOT NULL IDENTITY(1,1) CONSTRAINT PK_DimCategory PRIMARY KEY,
    CategoryName VARCHAR(50) NOT NULL,
    CategoryCode VARCHAR(50) NOT NULL,
    TransactionType TINYINT NOT NULL CONSTRAINT CK_DimCategory_TransactionType CHECK (TransactionType IN (0,1)),
    DisplayOrder INT NOT NULL,
    CreatedAt DATETIME2(3) NOT NULL CONSTRAINT DF_DimCategory_CreatedAt DEFAULT SYSUTCDATETIME(),

    -- Unicidade por: code + type
    CONSTRAINT UQ_DimCategory_Code_Type UNIQUE (CategoryCode, TransactionType)
);
GO

/* Lookup rápido do CategoryId por CategoryCode e TransactionType */
CREATE INDEX IX_DimCategory_Lookup_OperationId
ON serving.DimCategory (CategoryCode, TransactionType)
INCLUDE (CategoryId, CategoryName, DisplayOrder);
GO

/* Garante unicidade por: (type + order) e uso para ordenar queries */
CREATE UNIQUE INDEX UQ_DimCategory_Type_DisplayOrder
ON serving.DimCategory(TransactionType, DisplayOrder)
INCLUDE(CategoryId, CategoryName);

CREATE TABLE serving.DimProduct
(
    ProductId INT NOT NULL IDENTITY(1,1) CONSTRAINT PK_DimProduct PRIMARY KEY,
	ProductName VARCHAR(50) NOT NULL,
    ProductCode VARCHAR(50) NOT NULL,
	CreatedAt DATETIME2(3) NOT NULL CONSTRAINT DF_DimProduct_CreatedAt DEFAULT SYSUTCDATETIME(),

	CONSTRAINT UQ_DimProduct_ProductCode UNIQUE (ProductCode)
);
GO

/* Lookup rápido do ProductId por ProductCode */
CREATE INDEX IX_DimProduct_Lookup_ProductCode
ON serving.DimProduct (ProductCode)
INCLUDE (ProductId, ProductName);
GO

CREATE TABLE serving.DimDate (
    DateId INT CONSTRAINT PK_DimDate PRIMARY KEY,
    [Date] DATE,
    [Year] INT,
    [Month] INT,
    [Week] INT,
    [Day] INT,
    CONSTRAINT UQ_DimData_Data UNIQUE ([Date]) -- por padrão nonclustered
);
GO

-- 2) Partition Function / Scheme (YearMonth)
-- Particionamento mensal por YearMonth
DECLARE @StartDate date = '2025-01-01';
DECLARE @EndDate   date = '2034-12-01';

DECLARE @sqlPF nvarchar(max) = N'
CREATE PARTITION FUNCTION PF_FactTransaction_YearMonth (int)
AS RANGE RIGHT FOR VALUES (';

DECLARE @d2 date = @StartDate;

WHILE @d2 <= @EndDate
BEGIN
    DECLARE @ym2 int = (YEAR(@d2) * 100) + MONTH(@d2);
    SET @sqlPF += CAST(@ym2 as nvarchar(10)) + N',';
    SET @d2 = DATEADD(month, 1, @d2);
END

SET @sqlPF = LEFT(@sqlPF, LEN(@sqlPF) - 1) + N');';

EXEC sys.sp_executesql @sqlPF;
GO

CREATE PARTITION SCHEME PS_FactTransaction_YearMonth
AS PARTITION PF_FactTransaction_YearMonth
ALL TO ([PRIMARY]);
GO

-- 3) Tabela FactTransaction (particionada)
-- FactTransaction (feed) com YearMonth derivado de DateId
-- Dedupe por UNIQUE(TransactionId) (global, não-alinhado)
-- Cluster físico em YearMonth + FactId para append
CREATE TABLE serving.FactTransaction
(
    -- Surrogate de linha para ordenação física (append eficiente)
    FactId BIGINT IDENTITY(1,1) NOT NULL,

    TransactionId UNIQUEIDENTIFIER NOT NULL,
    OriginalTransactionId UNIQUEIDENTIFIER NOT NULL,
    EntryId BIGINT NOT NULL,
    ClientId INT NOT NULL,
    DateId INT NOT NULL, -- YYYYMMDD (conforme DimDate)
    ProductId INT NOT NULL,
    CategoryId INT NOT NULL,
    Amount DECIMAL(18,2) NOT NULL,
    Description VARCHAR(255) NULL,
    OccurredAt DATETIME2(3) NOT NULL, -- OccurredAt (horário local (America/Sao_Paulo) do domínio)
    CreatedAt DATETIME2(3) NOT NULL CONSTRAINT DF_Fact_CreatedAt DEFAULT SYSUTCDATETIME(), -- UTC

    -- Derivado para particionamento
    YearMonth AS (DateId / 100) PERSISTED,

    -- FKs
    CONSTRAINT FK_Fact_Client  FOREIGN KEY (ClientId)  REFERENCES serving.DimClient(ClientId),
    CONSTRAINT FK_Fact_Date    FOREIGN KEY (DateId)    REFERENCES serving.DimDate(DateId),
    CONSTRAINT FK_Fact_Product FOREIGN KEY (ProductId) REFERENCES serving.DimProduct(ProductId),
    CONSTRAINT FK_Fact_Category FOREIGN KEY (CategoryId) REFERENCES serving.DimCategory(CategoryId),

    -- PK lógica (não-alinhada) (global) em [PRIMARY] - Evitar Bugs
    CONSTRAINT PK_Fact_Transaction PRIMARY KEY NONCLUSTERED (FactId) ON [PRIMARY]
)
ON PS_FactTransaction_YearMonth (YearMonth);
GO

/* Clustered Index alinhado ao particionamento
   - Ordena fisicamente por (YearMonth, FactId) para append eficiente
   - Evita GUID não-sequencial como clustered
*/
CREATE CLUSTERED INDEX CX_FactTransaction_YearMonth_RowId
ON serving.FactTransaction (YearMonth, FactId)
ON PS_FactTransaction_YearMonth (YearMonth);
GO

/* Índice UNIQUE global (não-alinhado) para dedupe
   - Garante que TransactionId único.
*/
CREATE UNIQUE INDEX UX_FactTransaction_Transaction_Global
ON serving.FactTransaction (TransactionId)
ON [PRIMARY];
GO

CREATE UNIQUE INDEX UX_FactTransaction_EntryId_Global
ON serving.FactTransaction (EntryId)
ON [PRIMARY];
GO

/* Índice para agregações
   - WHERE ClientId = ? AND DateId BETWEEN ...
   - GROUP BY Category/Product (sem necessidade de lookup em muitos casos)
*/
CREATE NONCLUSTERED INDEX IDX_FactTransaction_Agg_Client_Date
ON serving.FactTransaction (ClientId, DateId)
INCLUDE (CategoryId, ProductId, Amount);
GO

/* Índice para listagem
   - WHERE ClientId = ? AND CategoryId = ? AND DateId BETWEEN ...
   - ORDER BY DateId DESC (paginação estável: DateId DESC, TransactionId)
*/
CREATE NONCLUSTERED INDEX IDX_FactTransaction_List_ClientCat_DateDesc
ON serving.FactTransaction (ClientId, CategoryId, OccurredAt DESC, TransactionId)
INCLUDE (Amount, Description, DateId, OriginalTransactionId);
GO

DECLARE @d date = '2025-01-01';
WHILE @d <= '2034-12-31'
BEGIN
    INSERT INTO serving.DimDate (DateID, [Date], [Year], [Month], [Week], [Day])
    VALUES (
        CONVERT(int, FORMAT(@d, 'yyyyMMdd')),
        @d,
        YEAR(@d),
        MONTH(@d),
        DATEPART(iso_week, @d),
        DAY(@d)
    );

    SET @d = DATEADD(day, 1, @d);
END;
GO

--========================================
--Base: truth
--========================================

IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'truth')
BEGIN
    EXEC('CREATE SCHEMA truth');
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = 'PF_TransactionEvent_YearMonth')
BEGIN
    DECLARE @StartDate date = '2025-01-01';
    DECLARE @EndDate   date = '2034-12-01';

    DECLARE @sql nvarchar(max) = N'
    CREATE PARTITION FUNCTION PF_TransactionEvent_YearMonth (int)
    AS RANGE RIGHT FOR VALUES (';

    DECLARE @d date = @StartDate;

    WHILE @d <= @EndDate
    BEGIN
        DECLARE @ym int = (YEAR(@d) * 100) + MONTH(@d);
        SET @sql += CAST(@ym as nvarchar(10)) + N',';
        SET @d = DATEADD(month, 1, @d);
    END

    SET @sql = LEFT(@sql, LEN(@sql) - 1) + N');';

    EXEC sys.sp_executesql @sql;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = 'PS_TransactionEvent_YearMonth')
BEGIN
    CREATE PARTITION SCHEME PS_TransactionEvent_YearMonth
    AS PARTITION PF_TransactionEvent_YearMonth
    ALL TO ([PRIMARY]); 
END 
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Product' AND schema_id = SCHEMA_ID('truth'))
BEGIN
    CREATE TABLE truth.Product
    (
        Id BIGINT IDENTITY(1,1) NOT NULL,
        ProductName     VARCHAR(255) NOT NULL,
        ProductCode     VARCHAR(255) NOT NULL,
        CONSTRAINT PK_Product_v1 PRIMARY KEY CLUSTERED (Id) ON [PRIMARY]
    )
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Category' AND schema_id = SCHEMA_ID('truth'))
BEGIN
    CREATE TABLE truth.Category
    (
        Id               BIGINT IDENTITY(1,1) NOT NULL,
        CategoryName     VARCHAR(255) NOT NULL,
        CategoryCode     VARCHAR(255) NOT NULL,
        TransactionType  TINYINT NOT NULL,
        DisplayOrder     TINYINT NOT NULL,
        CONSTRAINT PK_Category_v1 PRIMARY KEY CLUSTERED (Id) ON [PRIMARY]
    )
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Operation' AND schema_id = SCHEMA_ID('truth'))
BEGIN
    CREATE TABLE truth.Operation
    (
        Id BIGINT IDENTITY(1,1) NOT NULL,
        OperationCode     BIGINT NOT NULL,
        ProductId	      BIGINT NOT NULL,
        CategoryId        BIGINT NOT NULL, 
        Active      TINYINT NOT NULL,
        CONSTRAINT PK_Operation_v1 PRIMARY KEY CLUSTERED (Id) ON [PRIMARY],
        CONSTRAINT FK_Operation_Product FOREIGN KEY (ProductId) REFERENCES truth.Product(Id),
        CONSTRAINT FK_Operation_Category FOREIGN KEY (CategoryId) REFERENCES truth.Category(Id)
    )
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'TransactionEvent' AND schema_id = SCHEMA_ID('truth'))
BEGIN
    CREATE TABLE truth.TransactionEvent
    (
        EventStoreId BIGINT IDENTITY(1,1) NOT NULL,
        CorrelationId UNIQUEIDENTIFIER NOT NULL,
        TransactionId UNIQUEIDENTIFIER NOT NULL,
		OriginalTransactionId UNIQUEIDENTIFIER NOT NULL,
        EntryId BIGINT NOT NULL,
        TradingAccount BIGINT NOT NULL,
        Brand          SMALLINT NOT NULL,
        TransactionType TINYINT NOT NULL, -- DEBIT/CREDIT (0/1)
        OperationId BIGINT NOT NULL,
        Amount DECIMAL(18,2) NOT NULL,
        Description VARCHAR(255) NOT NULL,
        PayloadJson NVARCHAR(MAX) NOT NULL,
        OccurredAt DATETIME2(3) NOT NULL,
        IngestedAt DATETIME2(3) NOT NULL CONSTRAINT DF_CTEv1_IngestedAt DEFAULT SYSUTCDATETIME(),
        YearMonth AS (DATEPART(year, OccurredAt) * 100 + DATEPART(month, OccurredAt)) PERSISTED,
        CONSTRAINT PK_CuratedTransactionEvent_v1 PRIMARY KEY NONCLUSTERED (EventStoreId) ON [PRIMARY],
        CONSTRAINT FK_TransactionEvent_Operation FOREIGN KEY (OperationId) REFERENCES truth.Operation(Id)
    )
    ON PS_TransactionEvent_YearMonth (YearMonth);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'CX_TransactionEvent_YearMonth_EventStoreId' AND object_id = OBJECT_ID('truth.TransactionEvent'))
BEGIN
    CREATE CLUSTERED INDEX CX_TransactionEvent_YearMonth_EventStoreId
    ON truth.TransactionEvent (YearMonth, EventStoreId)
    ON PS_TransactionEvent_YearMonth (YearMonth);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_TransactionEvent_Transaction' AND object_id = OBJECT_ID('truth.TransactionEvent'))
BEGIN
    CREATE UNIQUE INDEX UX_TransactionEvent_Transaction
    ON truth.TransactionEvent (TransactionId)
    ON [PRIMARY];
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_TransactionEvent_EntryId' AND object_id = OBJECT_ID('truth.TransactionEvent'))
BEGIN
	CREATE UNIQUE INDEX UX_TransactionEvent_EntryId
	ON truth.TransactionEvent (EntryId)
	ON [PRIMARY];
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_TransactionEvent_TradingAccount_Brand_YearMonth' AND object_id = OBJECT_ID('truth.TransactionEvent'))
BEGIN
    CREATE INDEX IX_TransactionEvent_TradingAccount_Brand_YearMonth
    ON truth.TransactionEvent (TradingAccount, Brand, YearMonth)
    INCLUDE (TransactionId, OperationId, TransactionType, Amount, OccurredAt, Description)
    ON PS_TransactionEvent_YearMonth (YearMonth);
END
GO

--========================================
--Load Data
--========================================

IF NOT EXISTS (SELECT 1 FROM [truth].[Category])
BEGIN
	INSERT INTO [truth].[Category] ([CategoryName],[CategoryCode],[TransactionType],[DisplayOrder]) VALUES
	-- Entrada
	(N'Salário','salario', 1, 1),
	(N'Transferências','transferencias', 1, 2),
	(N'Resgates','resgates', 1, 3),
	(N'Outros','outros', 1, 4),

	-- Saídas
	(N'Cartão','cartao', 0, 1),
	(N'Contas recorrentes','contas-recorrentes', 0, 2),
	(N'Transferências','transferencias', 0, 3),
	(N'Investimentos','investimentos', 0, 4),
	(N'Débito e saques','debito-e-saques', 0, 5),
	(N'Outros','outros', 0, 6);
END
GO

IF NOT EXISTS (SELECT 1 FROM [truth].[Product])
BEGIN
    INSERT INTO [truth].[Product] ([ProductName], [ProductCode]) Values
	(N'Bloqueios','bloqueios'), -- 1
	(N'Câmbio','cambio'), -- 2
	(N'Campanhas','campanhas'), -- 3
	(N'Cartão','cartao'), -- 4
	(N'Cartão de débito','cartao-de-debito'), -- 5
	(N'Cashback','cashback'), -- 6
	(N'Crédito','credito'), -- 7
	(N'Fundos','fundos'), -- 8
	(N'Outros','outros'), -- 9
	(N'Pagamentos','pagamentos'), -- 10
	(N'Pix','pix'), -- 11
	(N'Previdência','previdencia'), -- 12
	(N'Rendimentos','rendimentos'), -- 13
	(N'Saque','saque'), -- 14
	(N'Seguros','seguros'), -- 15
	(N'TED','ted'), -- 16
	(N'TEF','tef'); -- 17
END
GO

IF NOT EXISTS (SELECT 1 FROM [serving].[DimCategory])
BEGIN
	INSERT INTO [serving].[DimCategory] ([CategoryName],[CategoryCode],[TransactionType],[DisplayOrder]) VALUES
	-- Entrada
	(N'Salário','salario', 1, 1),
	(N'Transferências','transferencias', 1, 2),
	(N'Resgates','resgates', 1, 3),
	(N'Outros','outros', 1, 4),

	-- Saídas
	(N'Cartão','cartao', 0, 1),
	(N'Contas recorrentes','contas-recorrentes', 0, 2),
	(N'Transferências','transferencias', 0, 3),
	(N'Investimentos','investimentos', 0, 4),
	(N'Débito e saques','debito-e-saques', 0, 5),
	(N'Outros','outros', 0, 6);
END
GO

IF NOT EXISTS (SELECT 1 FROM [serving].[DimProduct])
BEGIN
    INSERT INTO [serving].[DimProduct] ([ProductName], [ProductCode]) Values
	(N'Bloqueios','bloqueios'), -- 1
	(N'Câmbio','cambio'), -- 2
	(N'Campanhas','campanhas'), -- 3
	(N'Cartão','cartao'), -- 4
	(N'Cartão de débito','cartao-de-debito'), -- 5
	(N'Cashback','cashback'), -- 6
	(N'Crédito','credito'), -- 7
	(N'Fundos','fundos'), -- 8
	(N'Outros','outros'), -- 9
	(N'Pagamentos','pagamentos'), -- 10
	(N'Pix','pix'), -- 11
	(N'Previdência','previdencia'), -- 12
	(N'Rendimentos','rendimentos'), -- 13
	(N'Saque','saque'), -- 14
	(N'Seguros','seguros'), -- 15
	(N'TED','ted'), -- 16
	(N'TEF','tef'); -- 17
END
GO

IF NOT EXISTS (SELECT 1 FROM [truth].[Operation] WHERE [OperationCode] = 1504)
BEGIN
	-- Consultas ID's das Categorias Entradas
	DECLARE @Salario SMALLINT;
	SELECT @Salario = Id FROM [truth].[Category] WHERE CategoryCode = 'salario' AND TransactionType = 1;

	DECLARE @TransferenciasEntrada SMALLINT;
	SELECT @TransferenciasEntrada = Id FROM [truth].[Category] WHERE CategoryCode = 'transferencias' AND TransactionType = 1;

	DECLARE @Resgates SMALLINT;
	SELECT @Resgates = Id FROM [truth].[Category] WHERE CategoryCode = 'resgates' AND TransactionType = 1;

	DECLARE @OutrosEntrada SMALLINT;
	SELECT @OutrosEntrada = Id FROM [truth].[Category] WHERE CategoryCode = 'outros' AND TransactionType = 1;

	-- Consultas ID's das Categorias Saídas
	DECLARE @Cartao SMALLINT;
	SELECT @Cartao = Id FROM [truth].[Category] WHERE CategoryCode = 'cartao' AND TransactionType = 0;

	DECLARE @ContasRecorrentes SMALLINT;
	SELECT @ContasRecorrentes = Id FROM [truth].[Category] WHERE CategoryCode = 'contas-recorrentes' AND TransactionType = 0;

	DECLARE @TransferenciasSaida SMALLINT;
	SELECT @TransferenciasSaida = Id FROM [truth].[Category] WHERE CategoryCode = 'transferencias' AND TransactionType = 0;

	DECLARE @Investimentos SMALLINT;
	SELECT @Investimentos = Id FROM [truth].[Category] WHERE CategoryCode = 'investimentos' AND TransactionType = 0;

	DECLARE @DebitoSaques SMALLINT;
	SELECT @DebitoSaques = Id FROM [truth].[Category] WHERE CategoryCode = 'debito-e-saques' AND TransactionType = 0;

	DECLARE @OutrosSaida SMALLINT;
	SELECT @OutrosSaida = Id FROM [truth].[Category] WHERE CategoryCode = 'outros' AND TransactionType = 0;

	-- Consultas ID's dos produtos
	DECLARE @BloqueiosProduct SMALLINT;
	SELECT @BloqueiosProduct = Id FROM [truth].[Product] WHERE ProductCode = 'bloqueios'; -- 1

	DECLARE @CambioProduct SMALLINT;
	SELECT @CambioProduct = Id FROM [truth].[Product] WHERE ProductCode = 'cambio'; -- 2

	DECLARE @CampanhasProduct SMALLINT;
	SELECT @CampanhasProduct = Id FROM [truth].[Product] WHERE ProductCode = 'campanhas'; -- 3

	DECLARE @CartaoProduct SMALLINT;
	SELECT @CartaoProduct = Id FROM [truth].[Product] WHERE ProductCode = 'cartao'; -- 4

	DECLARE @CartaoDebitoProduct SMALLINT;
	SELECT @CartaoDebitoProduct = Id FROM [truth].[Product] WHERE ProductCode = 'cartao-de-debito'; -- 5

	DECLARE @CashbackProduct SMALLINT;
	SELECT @CashbackProduct = Id FROM [truth].[Product] WHERE ProductCode = 'cashback'; -- 6

	DECLARE @CreditoProduct SMALLINT;
	SELECT @CreditoProduct = Id FROM [truth].[Product] WHERE ProductCode = 'credito'; -- 7

	DECLARE @FundosProduct SMALLINT;
	SELECT @FundosProduct = Id FROM [truth].[Product] WHERE ProductCode = 'fundos'; -- 8

	DECLARE @OutrosProduct SMALLINT;
	SELECT @OutrosProduct = Id FROM [truth].[Product] WHERE ProductCode = 'outros'; -- 9

	DECLARE @PagamentosProduct SMALLINT;
	SELECT @PagamentosProduct = Id FROM [truth].[Product] WHERE ProductCode = 'pagamentos'; -- 10

	DECLARE @PixProduct SMALLINT;
	SELECT @PixProduct = Id FROM [truth].[Product] WHERE ProductCode = 'pix'; -- 11

	DECLARE @PrevidenciaProduct SMALLINT;
	SELECT @PrevidenciaProduct = Id FROM [truth].[Product] WHERE ProductCode = 'previdencia'; -- 12

	DECLARE @RendimentosProduct SMALLINT;
	SELECT @RendimentosProduct = Id FROM [truth].[Product] WHERE ProductCode = 'rendimentos'; -- 13

	DECLARE @SaqueProduct SMALLINT;
	SELECT @SaqueProduct = Id FROM [truth].[Product] WHERE ProductCode = 'saque'; -- 14

	DECLARE @SegurosProduct SMALLINT;
	SELECT @SegurosProduct = Id FROM [truth].[Product] WHERE ProductCode = 'seguros'; -- 15

	DECLARE @TedProduct SMALLINT;
	SELECT @TedProduct = Id FROM [truth].[Product] WHERE ProductCode = 'ted'; -- 16

	DECLARE @TefProduct SMALLINT;
	SELECT @TefProduct = Id FROM [truth].[Product] WHERE ProductCode = 'tef'; -- 17

	INSERT INTO [truth].[Operation] ([OperationCode],[ProductId],[CategoryId],[Active]) VALUES
	(1,@OutrosProduct,@OutrosEntrada,1),
	(2,@OutrosProduct,@OutrosSaida,1),
	(92,@CreditoProduct,@OutrosSaida,1),
	(93,@CreditoProduct,@OutrosEntrada,1),
	(94,@CreditoProduct,@OutrosEntrada,1),
	(95,@CreditoProduct,@OutrosSaida,1),
	(96,@CreditoProduct,@OutrosSaida,1),
	(97,@CreditoProduct,@OutrosEntrada,1),
	(98,@CreditoProduct,@OutrosEntrada,1),
	(99,@CreditoProduct,@OutrosSaida,1),
	(100,@OutrosProduct,@OutrosSaida,1),
	(101,@OutrosProduct,@OutrosEntrada,1),
	(102,@CreditoProduct,@OutrosSaida,1),
	(103,@CreditoProduct,@OutrosEntrada,1),
	(104,@CreditoProduct,@OutrosEntrada,1),
	(105,@CreditoProduct,@OutrosSaida,1),
	(106,@OutrosProduct,@OutrosSaida,1),
	(107,@OutrosProduct,@OutrosEntrada,1),
	(108,@CreditoProduct,@OutrosSaida,1),
	(109,@CreditoProduct,@OutrosEntrada,1),
	(156,@OutrosProduct,@OutrosSaida,1),
	(157,@OutrosProduct,@OutrosEntrada,1),
	(158,@OutrosProduct,@OutrosSaida,1),
	(161,@OutrosProduct,@OutrosEntrada,1),
	(162,@OutrosProduct,@OutrosSaida,1),
	(163,@OutrosProduct,@OutrosEntrada,1),
	(187,@PagamentosProduct,@OutrosEntrada,1),
	(188,@PagamentosProduct,@OutrosSaida,1),
	(201,@CashbackProduct,@OutrosEntrada,1),
	(202,@CashbackProduct,@OutrosSaida,1),
	(203,@CashbackProduct,@OutrosSaida,1),
	(204,@CashbackProduct,@OutrosEntrada,1),
	(213,@CashbackProduct,@OutrosEntrada,1),
	(214,@CashbackProduct,@OutrosSaida,1),
	(218,@PrevidenciaProduct,@OutrosEntrada,1),
	(219,@PrevidenciaProduct,@OutrosEntrada,1),
	(220,@PrevidenciaProduct,@OutrosSaida,1),
	(221,@PrevidenciaProduct,@OutrosSaida,1),
	(222,@PrevidenciaProduct,@OutrosSaida,1),
	(223,@PrevidenciaProduct,@OutrosEntrada,1),
	(226,@TedProduct,@OutrosSaida,1),
	(227,@TedProduct,@OutrosEntrada,1),
	(228,@TedProduct,@OutrosSaida,1),
	(271,@TedProduct,@OutrosEntrada,1),
	(272,@PrevidenciaProduct,@OutrosSaida,1),
	(273,@PrevidenciaProduct,@OutrosEntrada,1),
	(274,@TedProduct,@OutrosEntrada,1),
	(279,@TedProduct,@OutrosEntrada,1),
	(280,@TedProduct,@OutrosEntrada,1),
	(283,@PrevidenciaProduct,@OutrosEntrada,1),
	(287,@PrevidenciaProduct,@OutrosEntrada,1),
	(288,@PrevidenciaProduct,@OutrosSaida,1),
	(289,@PrevidenciaProduct,@OutrosSaida,1),
	(290,@PrevidenciaProduct,@OutrosEntrada,1),
	(291,@TedProduct,@OutrosSaida,1),
	(302,@TedProduct,@OutrosEntrada,1),
	(303,@PrevidenciaProduct,@OutrosEntrada,1),
	(304,@PrevidenciaProduct,@OutrosSaida,1),
	(305,@TedProduct,@OutrosSaida,1),
	(329,@PrevidenciaProduct,@OutrosEntrada,1),
	(330,@PrevidenciaProduct,@OutrosEntrada,1),
	(331,@PrevidenciaProduct,@OutrosSaida,1),
	(332,@PrevidenciaProduct,@OutrosEntrada,1),
	(333,@PrevidenciaProduct,@OutrosSaida,1),
	(334,@PrevidenciaProduct,@OutrosEntrada,1),
	(335,@PrevidenciaProduct,@OutrosSaida,1),
	(336,@PrevidenciaProduct,@OutrosSaida,1),
	(337,@PrevidenciaProduct,@OutrosEntrada,1),
	(338,@PrevidenciaProduct,@OutrosEntrada,1),
	(339,@PrevidenciaProduct,@OutrosSaida,1),
	(340,@PrevidenciaProduct,@OutrosEntrada,1),
	(345,@PrevidenciaProduct,@OutrosEntrada,1),
	(346,@PrevidenciaProduct,@OutrosSaida,1),
	(347,@PrevidenciaProduct,@OutrosEntrada,1),
	(352,@PrevidenciaProduct,@OutrosSaida,1),
	(354,@PrevidenciaProduct,@OutrosSaida,1),
	(388,@PrevidenciaProduct,@OutrosSaida,1),
	(389,@PrevidenciaProduct,@OutrosEntrada,1),
	(390,@PrevidenciaProduct,@OutrosEntrada,1),
	(393,@PrevidenciaProduct,@OutrosEntrada,1),
	(394,@PrevidenciaProduct,@OutrosSaida,1),
	(395,@PrevidenciaProduct,@OutrosEntrada,1),
	(405,@PrevidenciaProduct,@OutrosEntrada,1),
	(406,@PrevidenciaProduct,@OutrosSaida,1),
	(407,@PrevidenciaProduct,@OutrosEntrada,1),
	(408,@PrevidenciaProduct,@OutrosSaida,1),
	(421,@PrevidenciaProduct,@OutrosSaida,1),
	(422,@PrevidenciaProduct,@OutrosEntrada,1),
	(423,@PrevidenciaProduct,@OutrosEntrada,1),
	(424,@PrevidenciaProduct,@OutrosSaida,1),
	(425,@PrevidenciaProduct,@OutrosEntrada,1),
	(426,@PrevidenciaProduct,@OutrosSaida,1),
	(427,@PrevidenciaProduct,@OutrosSaida,1),
	(428,@PrevidenciaProduct,@OutrosEntrada,1),
	(433,@PrevidenciaProduct,@OutrosEntrada,1),
	(435,@PrevidenciaProduct,@OutrosSaida,1),
	(437,@PrevidenciaProduct,@OutrosSaida,1),
	(438,@PrevidenciaProduct,@OutrosEntrada,1),
	(466,@TedProduct,@OutrosSaida,1),
	(472,@TedProduct,@OutrosSaida,1),
	(478,@PrevidenciaProduct,@OutrosSaida,1),
	(479,@PrevidenciaProduct,@OutrosEntrada,1),
	(487,@PrevidenciaProduct,@OutrosEntrada,1),
	(488,@PrevidenciaProduct,@OutrosSaida,1),
	(489,@PrevidenciaProduct,@OutrosSaida,1),
	(490,@PrevidenciaProduct,@OutrosEntrada,1),
	(496,@CambioProduct,@OutrosSaida,1),
	(499,@CambioProduct,@OutrosEntrada,1),
	(500,@CambioProduct,@OutrosSaida,1),
	(501,@CambioProduct,@OutrosEntrada,1),
	(502,@CambioProduct,@OutrosSaida,1),
	(503,@CambioProduct,@OutrosSaida,1),
	(504,@CambioProduct,@OutrosEntrada,1),
	(505,@CambioProduct,@OutrosSaida,1),
	(506,@CambioProduct,@OutrosEntrada,1),
	(507,@CambioProduct,@OutrosSaida,1),
	(508,@CambioProduct,@OutrosEntrada,1),
	(509,@PrevidenciaProduct,@OutrosSaida,1),
	(510,@PrevidenciaProduct,@OutrosEntrada,1),
	(511,@CambioProduct,@OutrosSaida,1),
	(512,@CambioProduct,@OutrosEntrada,1),
	(513,@CambioProduct,@OutrosSaida,1),
	(514,@CambioProduct,@OutrosSaida,1),
	(515,@CambioProduct,@OutrosSaida,1),
	(516,@CambioProduct,@OutrosEntrada,1),
	(517,@CambioProduct,@OutrosSaida,1),
	(518,@CambioProduct,@OutrosEntrada,1),
	(523,@PrevidenciaProduct,@OutrosSaida,1),
	(524,@PrevidenciaProduct,@OutrosSaida,1),
	(525,@PrevidenciaProduct,@OutrosSaida,1),
	(526,@PrevidenciaProduct,@OutrosEntrada,1),
	(527,@TedProduct,@OutrosEntrada,1),
	(528,@PrevidenciaProduct,@OutrosEntrada,1),
	(529,@CambioProduct,@OutrosEntrada,1),
	(531,@TedProduct,@OutrosSaida,1),
	(532,@PrevidenciaProduct,@OutrosSaida,1),
	(533,@PrevidenciaProduct,@OutrosEntrada,1),
	(534,@TedProduct,@OutrosSaida,1),
	(535,@PrevidenciaProduct,@OutrosEntrada,1),
	(536,@PrevidenciaProduct,@OutrosEntrada,1),
	(537,@PrevidenciaProduct,@OutrosSaida,1),
	(538,@PrevidenciaProduct,@OutrosSaida,1),
	(545,@PrevidenciaProduct,@OutrosSaida,1),
	(546,@PrevidenciaProduct,@OutrosEntrada,1),
	(549,@OutrosProduct,@OutrosSaida,1),
	(574,@OutrosProduct,@OutrosSaida,1),
	(575,@OutrosProduct,@OutrosEntrada,1),
	(727,@OutrosProduct,@OutrosEntrada,1),
	(729,@OutrosProduct,@OutrosSaida,1),
	(778,@PixProduct,@OutrosSaida,1),
	(779,@SaqueProduct,@OutrosEntrada,1),
	(781,@OutrosProduct,@OutrosEntrada,1),
	(782,@PixProduct,@OutrosSaida,1),
	(783,@PixProduct,@OutrosEntrada,1),
	(785,@PixProduct,@OutrosEntrada,1),
	(786,@PixProduct,@OutrosSaida,1),
	(787,@PixProduct,@OutrosEntrada,1),
	(819,@OutrosProduct,@OutrosSaida,1),
	(820,@OutrosProduct,@OutrosEntrada,1),
	(821,@CambioProduct,@OutrosEntrada,1),
	(822,@CambioProduct,@OutrosSaida,1),
	(823,@OutrosProduct,@OutrosEntrada,1),
	(824,@OutrosProduct,@OutrosSaida,1),
	(826,@OutrosProduct,@OutrosEntrada,1),
	(827,@OutrosProduct,@OutrosSaida,1),
	(828,@OutrosProduct,@OutrosEntrada,1),
	(829,@OutrosProduct,@OutrosEntrada,1),
	(830,@OutrosProduct,@OutrosSaida,1),
	(831,@OutrosProduct,@OutrosEntrada,1),
	(847,@SegurosProduct,@OutrosSaida,1),
	(859,@OutrosProduct,@OutrosSaida,1),
	(969,@OutrosProduct,@OutrosSaida,1),
	(970,@OutrosProduct,@OutrosEntrada,1),
	(971,@OutrosProduct,@OutrosEntrada,1),
	(972,@OutrosProduct,@OutrosSaida,1),
	(973,@OutrosProduct,@OutrosEntrada,1),
	(974,@OutrosProduct,@OutrosSaida,1),
	(975,@CambioProduct,@OutrosSaida,1),
	(976,@CambioProduct,@OutrosSaida,1),
	(977,@CambioProduct,@OutrosEntrada,1),
	(978,@CambioProduct,@OutrosSaida,1),
	(979,@CambioProduct,@OutrosEntrada,1),
	(980,@CambioProduct,@OutrosSaida,1),
	(981,@OutrosProduct,@OutrosSaida,1),
	(982,@OutrosProduct,@OutrosEntrada,1),
	(983,@OutrosProduct,@OutrosEntrada,1),
	(1026,@TedProduct,@OutrosSaida,1),
	(1031,@PagamentosProduct,@OutrosSaida,1),
	(1033,@PagamentosProduct,@OutrosSaida,1),
	(1034,@SaqueProduct,@OutrosEntrada,1),
	(1036,@SaqueProduct,@OutrosEntrada,1),
	(1039,@SaqueProduct,@OutrosSaida,1),
	(1040,@SaqueProduct,@OutrosSaida,1),
	(1041,@SaqueProduct,@OutrosSaida,1),
	(1042,@SaqueProduct,@OutrosSaida,1),
	(1043,@SaqueProduct,@OutrosSaida,1),
	(1045,@PagamentosProduct,@OutrosEntrada,1),
	(1054,@CambioProduct,@OutrosSaida,1),
	(1055,@CambioProduct,@OutrosEntrada,1),
	(1056,@CambioProduct,@OutrosSaida,1),
	(1058,@TedProduct,@OutrosEntrada,1),
	(1060,@TedProduct,@OutrosSaida,1),
	(1062,@TedProduct,@OutrosSaida,1),
	(1064,@TedProduct,@OutrosEntrada,1),
	(1065,@CreditoProduct,@OutrosSaida,1),
	(1066,@CreditoProduct,@OutrosEntrada,1),
	(1067,@CreditoProduct,@OutrosSaida,1),
	(1068,@CartaoProduct,@OutrosEntrada,1),
	(1069,@TedProduct,@OutrosSaida,1),
	(1070,@TedProduct,@OutrosEntrada,1),
	(1071,@CambioProduct,@OutrosSaida,1),
	(1072,@CambioProduct,@OutrosEntrada,1),
	(1073,@TedProduct,@OutrosSaida,1),
	(1074,@TedProduct,@OutrosEntrada,1),
	(1075,@TedProduct,@OutrosSaida,1),
	(1076,@TedProduct,@OutrosEntrada,1),
	(1077,@PixProduct,@OutrosSaida,1),
	(1078,@PixProduct,@OutrosEntrada,1),
	(1079,@TedProduct,@OutrosSaida,1),
	(1080,@TedProduct,@OutrosEntrada,1),
	(1081,@TedProduct,@OutrosSaida,1),
	(1082,@TedProduct,@OutrosEntrada,1),
	(1083,@TedProduct,@OutrosSaida,1),
	(1084,@TedProduct,@OutrosEntrada,1),
	(1085,@TedProduct,@OutrosSaida,1),
	(1086,@TedProduct,@OutrosEntrada,1),
	(1087,@TedProduct,@OutrosSaida,1),
	(1088,@CreditoProduct,@OutrosSaida,1),
	(1090,@CartaoProduct,@OutrosSaida,1),
	(1092,@TedProduct,@OutrosSaida,1),
	(1094,@CambioProduct,@OutrosSaida,1),
	(1096,@TedProduct,@OutrosSaida,1),
	(1098,@TedProduct,@OutrosSaida,1),
	(1100,@PixProduct,@OutrosSaida,1),
	(1102,@TedProduct,@OutrosSaida,1),
	(1104,@TedProduct,@OutrosSaida,1),
	(1106,@TedProduct,@OutrosSaida,1),
	(1107,@TedProduct,@OutrosEntrada,1),
	(1108,@TedProduct,@OutrosSaida,1),
	(1109,@TedProduct,@OutrosEntrada,1),
	(1116,@PagamentosProduct,@OutrosSaida,1),
	(1121,@PixProduct,@OutrosSaida,1),
	(1124,@PixProduct,@OutrosSaida,1),
	(1125,@PixProduct,@OutrosSaida,1),
	(1135,@CreditoProduct,@OutrosEntrada,1),
	(1138,@PagamentosProduct,@OutrosSaida,1),
	(1145,@CreditoProduct,@OutrosSaida,1),
	(1146,@TefProduct,@OutrosSaida,1),
	(1147,@PixProduct,@OutrosSaida,1),
	(1151,@PixProduct,@OutrosEntrada,1),
	(1152,@PixProduct,@OutrosSaida,1),
	(1153,@PixProduct,@OutrosSaida,1),
	(1154,@TedProduct,@OutrosSaida,1),
	(1165,@TedProduct,@OutrosEntrada,1),
	(1166,@TedProduct,@OutrosSaida,1),
	(1177,@TedProduct,@OutrosEntrada,1),
	(1182,@PixProduct,@OutrosSaida,1),
	(1187,@TedProduct,@OutrosSaida,1),
	(1188,@TedProduct,@OutrosEntrada,1),
	(1190,@CartaoProduct,@OutrosSaida,1),
	(1196,@TedProduct,@OutrosSaida,1),
	(1197,@TedProduct,@OutrosEntrada,1),
	(1198,@TedProduct,@OutrosEntrada,1),
	(1199,@TedProduct,@OutrosSaida,1),
	(1203,@SaqueProduct,@OutrosSaida,1),
	(1210,@TedProduct,@OutrosSaida,1),
	(1211,@TedProduct,@OutrosEntrada,1),
	(1212,@TedProduct,@OutrosSaida,1),
	(1213,@TedProduct,@OutrosEntrada,1),
	(1214,@TedProduct,@OutrosEntrada,1),
	(1217,@PagamentosProduct,@OutrosSaida,1),
	(1221,@PagamentosProduct,@OutrosSaida,1),
	(1222,@TedProduct,@OutrosEntrada,1),
	(1227,@TedProduct,@OutrosSaida,1),
	(1230,@TedProduct,@OutrosSaida,1),
	(1233,@TedProduct,@OutrosSaida,1),
	(1234,@TedProduct,@OutrosEntrada,1),
	(1235,@TedProduct,@OutrosSaida,1),
	(1236,@TedProduct,@OutrosEntrada,1),
	(1237,@TedProduct,@OutrosSaida,1),
	(1238,@TedProduct,@OutrosSaida,1),
	(1239,@TedProduct,@OutrosEntrada,1),
	(1242,@CreditoProduct,@OutrosSaida,1),
	(1244,@TedProduct,@OutrosSaida,1),
	(1245,@PagamentosProduct,@OutrosSaida,1),
	(1253,@CambioProduct,@OutrosSaida,1),
	(1254,@CambioProduct,@OutrosSaida,1),
	(1255,@CambioProduct,@OutrosSaida,1),
	(1256,@CambioProduct,@OutrosSaida,1),
	(1258,@CambioProduct,@OutrosEntrada,1),
	(1259,@CambioProduct,@OutrosEntrada,1),
	(1260,@CambioProduct,@OutrosEntrada,1),
	(1261,@CambioProduct,@OutrosEntrada,1),
	(1262,@CambioProduct,@OutrosSaida,1),
	(1266,@CambioProduct,@OutrosEntrada,1),
	(1267,@CambioProduct,@OutrosEntrada,1),
	(1268,@CambioProduct,@OutrosEntrada,1),
	(1269,@CambioProduct,@OutrosEntrada,1),
	(1271,@TefProduct,@OutrosEntrada,1),
	(1276,@CartaoDebitoProduct,@OutrosEntrada,1),
	(1280,@PagamentosProduct,@OutrosEntrada,1),
	(1283,@TefProduct,@OutrosSaida,1),
	(1285,@SaqueProduct,@OutrosEntrada,1),
	(1287,@PagamentosProduct,@OutrosEntrada,1),
	(1290,@TedProduct,@OutrosSaida,1),
	(1291,@PixProduct,@OutrosSaida,1),
	(1292,@PixProduct,@OutrosEntrada,1),
	(1295,@PagamentosProduct,@OutrosEntrada,1),
	(1296,@PagamentosProduct,@OutrosSaida,1),
	(1297,@PagamentosProduct,@OutrosSaida,1),
	(1298,@PagamentosProduct,@OutrosEntrada,1),
	(1299,@TefProduct,@OutrosEntrada,1),
	(1302,@PagamentosProduct,@OutrosEntrada,1),
	(1303,@CreditoProduct,@OutrosSaida,1),
	(1306,@PagamentosProduct,@OutrosSaida,1),
	(1308,@CreditoProduct,@OutrosSaida,1),
	(1310,@CreditoProduct,@OutrosEntrada,1),
	(1311,@CreditoProduct,@OutrosSaida,1),
	(1312,@CreditoProduct,@OutrosSaida,1),
	(1314,@SaqueProduct,@OutrosSaida,1),
	(1322,@TedProduct,@OutrosEntrada,1),
	(1323,@CreditoProduct,@OutrosEntrada,1),
	(1325,@CreditoProduct,@OutrosSaida,1),
	(1326,@CreditoProduct,@OutrosEntrada,1),
	(1327,@CreditoProduct,@OutrosSaida,1),
	(1328,@CreditoProduct,@OutrosEntrada,1),
	(1340,@CreditoProduct,@OutrosEntrada,1),
	(1351,@CambioProduct,@OutrosEntrada,1),
	(1353,@CambioProduct,@OutrosSaida,1),
	(1355,@CambioProduct,@OutrosEntrada,1),
	(1356,@CambioProduct,@OutrosSaida,1),
	(1357,@CambioProduct,@OutrosSaida,1),
	(1358,@CambioProduct,@OutrosEntrada,1),
	(1363,@CreditoProduct,@OutrosSaida,1),
	(1365,@CreditoProduct,@OutrosEntrada,1),
	(1367,@CreditoProduct,@OutrosEntrada,1),
	(1369,@CreditoProduct,@OutrosSaida,1),
	(1392,@CreditoProduct,@OutrosEntrada,1),
	(1397,@CreditoProduct,@OutrosSaida,1),
	(1398,@CreditoProduct,@OutrosEntrada,1),
	(1404,@CambioProduct,@OutrosSaida,1),
	(1405,@TedProduct,@OutrosEntrada,1),
	(1406,@TedProduct,@OutrosEntrada,1),
	(1407,@CambioProduct,@OutrosEntrada,1),
	(1412,@CreditoProduct,@OutrosEntrada,1),
	(1434,@CreditoProduct,@OutrosEntrada,1),
	(1435,@CreditoProduct,@OutrosSaida,1),
	(1436,@CreditoProduct,@OutrosEntrada,1),
	(1440,@CreditoProduct,@OutrosSaida,1),
	(1441,@CreditoProduct,@OutrosEntrada,1),
	(1442,@CreditoProduct,@OutrosSaida,1),
	(1443,@CreditoProduct,@OutrosEntrada,1),
	(1444,@CreditoProduct,@OutrosSaida,1),
	(1445,@CreditoProduct,@OutrosEntrada,1),
	(1446,@CreditoProduct,@OutrosEntrada,1),
	(1447,@CreditoProduct,@OutrosSaida,1),
	(1448,@CreditoProduct,@OutrosEntrada,1),
	(1449,@CreditoProduct,@OutrosSaida,1),
	(1451,@CreditoProduct,@OutrosSaida,1),
	(1452,@CreditoProduct,@OutrosSaida,1),
	(1453,@CreditoProduct,@OutrosEntrada,1),
	(1462,@CreditoProduct,@OutrosSaida,1),
	(1463,@CreditoProduct,@OutrosEntrada,1),
	(1468,@CreditoProduct,@OutrosSaida,1),
	(1469,@CreditoProduct,@OutrosEntrada,1),
	(1470,@TedProduct,@OutrosSaida,1),
	(1471,@TedProduct,@OutrosEntrada,1),
	(1472,@CreditoProduct,@OutrosSaida,1),
	(1473,@CreditoProduct,@OutrosEntrada,1),
	(1476,@CreditoProduct,@OutrosEntrada,1),
	(1478,@CreditoProduct,@OutrosSaida,1),
	(1479,@CreditoProduct,@OutrosEntrada,1),
	(1480,@CreditoProduct,@OutrosSaida,1),
	(1486,@TedProduct,@OutrosEntrada,1),
	(1493,@TedProduct,@OutrosEntrada,1),
	(1498,@CreditoProduct,@OutrosEntrada,1),
	(1500,@CreditoProduct,@OutrosSaida,1),
	(417,@PixProduct,@OutrosSaida,1),
	(409,@PixProduct,@TransferenciasSaida,1),
	(411,@PixProduct,@TransferenciasEntrada,1),
	(419,@PixProduct,@OutrosEntrada,1),
	(764,@CartaoDebitoProduct,@DebitoSaques,1),
	(1178,@RendimentosProduct,@OutrosEntrada,1),
	(1057,@TedProduct,@Investimentos,1),
	(1061,@TedProduct,@Resgates,1),
	(1025,@TedProduct,@OutrosEntrada,1),
	(1059,@TedProduct,@Resgates,1),
	(1063,@TedProduct,@Investimentos,1),
	(471,@TedProduct,@TransferenciasEntrada,1),
	(1246,@PagamentosProduct,@OutrosEntrada,1),
	(1286,@PagamentosProduct,@ContasRecorrentes,1),
	(1024,@TedProduct,@OutrosSaida,1),
	(1279,@PagamentosProduct,@Cartao,1),
	(1049,@TedProduct,@Investimentos,1),
	(465,@TedProduct,@TransferenciasEntrada,1),
	(1120,@PixProduct,@TransferenciasSaida,1),
	(1206,@TedProduct,@OutrosSaida,1),
	(459,@PagamentosProduct,@ContasRecorrentes,1),
	(461,@PagamentosProduct,@OutrosEntrada,1),
	(415,@PixProduct,@TransferenciasEntrada,1),
	(413,@PixProduct,@TransferenciasSaida,1),
	(410,@PixProduct,@OutrosEntrada,1),
	(418,@PixProduct,@OutrosEntrada,1),
	(572,@TedProduct,@Salario,1),
	(1114,@CreditoProduct,@OutrosSaida,1),
	(469,@TedProduct,@TransferenciasSaida,1),
	(815,@CartaoDebitoProduct,@OutrosEntrada,1),
	(941,@SaqueProduct,@DebitoSaques,1),
	(463,@TedProduct,@TransferenciasSaida,1),
	(1208,@FundosProduct,@OutrosSaida,1),
	(1209,@FundosProduct,@OutrosEntrada,1),
	(1150,@CreditoProduct,@OutrosSaida,1),
	(420,@PixProduct,@OutrosSaida,1),
	(412,@PixProduct,@OutrosSaida,1),
	(1136,@PagamentosProduct,@ContasRecorrentes,1),
	(1137,@PagamentosProduct,@OutrosEntrada,1),
	(498,@CambioProduct,@OutrosSaida,1),
	(1148,@CreditoProduct,@OutrosSaida,1),
	(1123,@PixProduct,@TransferenciasSaida,1),
	(1110,@PagamentosProduct,@ContasRecorrentes,1),
	(1111,@PagamentosProduct,@OutrosEntrada,1),
	(1366,@TedProduct,@OutrosSaida,1),
	(1368,@TedProduct,@OutrosEntrada,1),
	(494,@CambioProduct,@OutrosSaida,1),
	(846,@SegurosProduct,@OutrosEntrada,1),
	(845,@SegurosProduct,@OutrosSaida,1),
	(1195,@TedProduct,@OutrosSaida,1),
	(1171,@CambioProduct,@OutrosSaida,1),
	(1175,@CambioProduct,@OutrosSaida,1),
	(1112,@CreditoProduct,@OutrosSaida,1),
	(1113,@CreditoProduct,@OutrosEntrada,1),
	(939,@CartaoDebitoProduct,@OutrosSaida,1),
	(937,@CartaoDebitoProduct,@DebitoSaques,1),
	(1247,@CreditoProduct,@OutrosEntrada,1),
	(1027,@OutrosProduct,@OutrosEntrada,1),
	(1200,@CartaoDebitoProduct,@DebitoSaques,1),
	(492,@CambioProduct,@OutrosEntrada,1),
	(1033,@BloqueiosProduct,@OutrosSaida,1),
	(1282,@BloqueiosProduct,@OutrosSaida,1),
	(464,@TedProduct,@TransferenciasEntrada,1),
	(943,@SaqueProduct,@OutrosSaida,1),
	(1373,@OutrosProduct,@OutrosSaida,1),
	(456,@BloqueiosProduct,@OutrosEntrada,1),
	(458,@BloqueiosProduct,@OutrosSaida,1),
	(432,@TedProduct,@TransferenciasSaida,1),
	(434,@TedProduct,@TransferenciasEntrada,1),
	(1149,@PixProduct,@OutrosSaida,1),
	(470,@TedProduct,@TransferenciasEntrada,1),
	(1339,@TedProduct,@TransferenciasSaida,1),
	(1179,@PixProduct,@OutrosEntrada,1),
	(1180,@CampanhasProduct,@OutrosSaida,1),
	(1173,@CambioProduct,@OutrosEntrada,1),
	(991,@PagamentosProduct,@OutrosEntrada,1),
	(1163,@CampanhasProduct,@OutrosSaida,1),
	(1161,@PixProduct,@OutrosEntrada,1),
	(1226,@FundosProduct,@Investimentos,1),
	(1225,@PixProduct,@OutrosEntrada,1),
	(570,@TedProduct,@TransferenciasSaida,1),
	(1052,@PixProduct,@OutrosEntrada,1),
	(1408,@TedProduct,@OutrosSaida,1),
	(1288,@PixProduct,@OutrosEntrada,1),
	(1289,@PixProduct,@OutrosSaida,1),
	(1309,@PixProduct,@OutrosEntrada,1),
	(1204,@TedProduct,@TransferenciasSaida,1),
	(938,@CartaoDebitoProduct,@OutrosEntrada,1),
	(1028,@CartaoDebitoProduct,@OutrosEntrada,1),
	(940,@CartaoDebitoProduct,@OutrosEntrada,1),
	(1224,@FundosProduct,@OutrosSaida,1),
	(1223,@PixProduct,@OutrosEntrada,1),
	(1346,@CartaoDebitoProduct,@OutrosEntrada,1),
	(1272,@TedProduct,@ContasRecorrentes,1),
	(1048,@CambioProduct,@OutrosEntrada,1),
	(414,@PixProduct,@TransferenciasEntrada,1),
	(416,@PixProduct,@TransferenciasSaida,1),
	(1243,@PixProduct,@OutrosEntrada,1),
	(942,@PixProduct,@OutrosEntrada,1),
	(1050,@PixProduct,@OutrosEntrada,1),
	(1141,@PixProduct,@TransferenciasSaida,1),
	(1354,@CambioProduct,@OutrosSaida,1),
	(945,@PixProduct,@OutrosSaida,1),
	(946,@PixProduct,@OutrosSaida,1),
	(1379,@PixProduct,@ContasRecorrentes,1),
	(1016,@PixProduct,@OutrosSaida,1),
	(460,@PixProduct,@OutrosSaida,1),
	(462,@PixProduct,@OutrosEntrada,1),
	(1344,@PixProduct,@OutrosSaida,1),
	(1345,@PixProduct,@OutrosEntrada,1),
	(1201,@CartaoDebitoProduct,@OutrosSaida,1),
	(1117,@TedProduct,@TransferenciasSaida,1),
	(1118,@TedProduct,@TransferenciasEntrada,1),
	(1317,@TedProduct,@TransferenciasSaida,1),
	(1350,@CambioProduct,@OutrosSaida,1),
	(1429,@TedProduct,@TransferenciasEntrada,1),
	(1249,@FundosProduct,@OutrosSaida,1),
	(1252,@CambioProduct,@OutrosSaida,1),
	(1130,@TedProduct,@TransferenciasEntrada,1),
	(1319,@TedProduct,@TransferenciasSaida,1),
	(1232,@PixProduct,@OutrosSaida,1),
	(1133,@PixProduct,@OutrosEntrada,1),
	(1352,@CambioProduct,@OutrosEntrada,1),
	(944,@PixProduct,@OutrosEntrada,1),
	(1119,@TedProduct,@TransferenciasSaida,1),
	(1315,@PrevidenciaProduct,@OutrosEntrada,1),
	(1128,@SegurosProduct,@OutrosEntrada,1),
	(1193,@PixProduct,@OutrosEntrada,1),
	(1391,@PixProduct,@OutrosSaida,1),
	(1364,@PixProduct,@OutrosSaida,1),
	(1167,@PixProduct,@OutrosSaida,1),
	(1168,@PixProduct,@OutrosEntrada,1),
	(1370,@PixProduct,@OutrosEntrada,1),
	(1132,@PixProduct,@OutrosSaida,1),
	(1191,@PixProduct,@OutrosEntrada,1),
	(1192,@PixProduct,@OutrosSaida,1),
	(1030,@CartaoDebitoProduct,@OutrosEntrada,1),
	(1032,@CartaoDebitoProduct,@OutrosEntrada,1),
	(1229,@PixProduct,@OutrosEntrada,1),
	(1304,@PixProduct,@OutrosSaida,1),
	(1387,@PixProduct,@OutrosSaida,1),
	(1305,@PixProduct,@OutrosEntrada,1),
	(726,@PixProduct,@OutrosSaida,1),
	(730,@PixProduct,@OutrosEntrada,1),
	(1207,@TedProduct,@OutrosEntrada,1),
	(1410,@TedProduct,@OutrosEntrada,1),
	(1160,@TedProduct,@OutrosEntrada,1),
	(728,@PixProduct,@OutrosEntrada,1),
	(733,@PixProduct,@OutrosSaida,1),
	(1157,@PixProduct,@OutrosSaida,1),
	(1140,@TedProduct,@OutrosSaida,1),
	(1401,@TedProduct,@OutrosSaida,1),
	(1115,@PixProduct,@OutrosSaida,1),
	(780,@PixProduct,@TransferenciasSaida,1),
	(784,@PixProduct,@OutrosSaida,1),
	(1395,@PixProduct,@OutrosEntrada,1),
	(1122,@PixProduct,@TransferenciasSaida,1),
	(1172,@CambioProduct,@OutrosEntrada,1),
	(1388,@PixProduct,@OutrosSaida,1),
	(1186,@CambioProduct,@OutrosEntrada,1),
	(1424,@PixProduct,@OutrosEntrada,1),
	(1400,@TedProduct,@OutrosSaida,1),
	(1403,@PixProduct,@OutrosSaida,1),
	(947,@PixProduct,@OutrosEntrada,1),
	(948,@PixProduct,@OutrosEntrada,1),
	(1483,@PixProduct,@OutrosSaida,1),
	(1017,@PixProduct,@OutrosEntrada,1),
	(1164,@CampanhasProduct,@OutrosEntrada,1),
	(1240,@CambioProduct,@OutrosSaida,1),
	(1162,@PixProduct,@OutrosSaida,1),
	(1250,@FundosProduct,@OutrosEntrada,1),
	(1372,@PixProduct,@OutrosSaida,1),
	(1334,@CambioProduct,@OutrosEntrada,1),
	(1091,@PagamentosProduct,@OutrosEntrada,1),
	(1127,@TedProduct,@OutrosSaida,1),
	(1095,@CambioProduct,@OutrosEntrada,1),
	(1402,@TedProduct,@OutrosSaida,1),
	(1380,@PixProduct,@ContasRecorrentes,1),
	(1423,@PixProduct,@OutrosEntrada,1),
	(1335,@PixProduct,@OutrosSaida,1),
	(1047,@PixProduct,@OutrosEntrada,1),
	(1336,@PixProduct,@OutrosSaida,1),
	(1131,@TedProduct,@OutrosSaida,1),
	(1046,@PixProduct,@OutrosEntrada,1),
	(1321,@TedProduct,@OutrosSaida,1),
	(1274,@PixProduct,@OutrosEntrada,1),
	(530,@FundosProduct,@OutrosSaida,1),
	(1181,@PixProduct,@TransferenciasSaida,1),
	(1183,@PixProduct,@TransferenciasEntrada,1),
	(1143,@TedProduct,@TransferenciasEntrada,1),
	(1176,@CambioProduct,@OutrosEntrada,1),
	(1089,@PixProduct,@OutrosEntrada,1),
	(1134,@PixProduct,@TransferenciasSaida,1),
	(1035,@PixProduct,@OutrosEntrada,1),
	(1394,@CambioProduct,@OutrosSaida,1),
	(1342,@TedProduct,@TransferenciasEntrada,1),
	(1474,@PixProduct,@OutrosEntrada,1),
	(1318,@TedProduct,@OutrosEntrada,1),
	(495,@CambioProduct,@OutrosEntrada,1),
	(1409,@CambioProduct,@OutrosSaida,1),
	(1381,@PixProduct,@OutrosSaida,1),
	(1185,@CambioProduct,@OutrosSaida,1),
	(1477,@PagamentosProduct,@TransferenciasEntrada,1),
	(1439,@PixProduct,@OutrosSaida,1),
	(1497,@PixProduct,@OutrosSaida,1),
	(1320,@TedProduct,@OutrosEntrada,1),
	(1376,@PixProduct,@OutrosEntrada,1),
	(1485,@TedProduct,@OutrosSaida,1),
	(1430,@PagamentosProduct,@ContasRecorrentes,1),
	(1431,@PixProduct,@OutrosEntrada,1),
	(1433,@PixProduct,@OutrosEntrada,1),
	(992,@PagamentosProduct,@OutrosSaida,1),
	(1251,@PixProduct,@OutrosEntrada,1),
	(1432,@PixProduct,@OutrosSaida,1),
	(1044,@PagamentosProduct,@ContasRecorrentes,1),
	(1374,@OutrosProduct,@OutrosEntrada,1),
	(1360,@PixProduct,@OutrosSaida,1),
	(1329,@CambioProduct,@OutrosSaida,1),
	(1419,@PixProduct,@OutrosEntrada,1),
	(1438,@PixProduct,@OutrosEntrada,1),
	(1458,@PixProduct,@OutrosEntrada,1),
	(1101,@PixProduct,@OutrosEntrada,1),
	(1361,@PixProduct,@OutrosEntrada,1),
	(1460,@PixProduct,@OutrosSaida,1),
	(1103,@PixProduct,@OutrosEntrada,1),
	(1220,@PixProduct,@OutrosEntrada,1),
	(1142,@TedProduct,@OutrosSaida,1),
	(1487,@TedProduct,@OutrosSaida,1),
	(1301,@CambioProduct,@OutrosEntrada,1),
	(1275,@PixProduct,@OutrosEntrada,1),
	(1475,@PixProduct,@OutrosEntrada,1),
	(1174,@CambioProduct,@OutrosSaida,1),
	(1341,@CambioProduct,@OutrosSaida,1),
	(455,@PixProduct,@OutrosSaida,1),
	(1170,@TedProduct,@OutrosEntrada,1),
	(1257,@CambioProduct,@OutrosEntrada,1),
	(1384,@CambioProduct,@OutrosEntrada,1),
	(1270,@FundosProduct,@OutrosSaida,1),
	(1411,@PixProduct,@OutrosSaida,1),
	(1499,@PixProduct,@OutrosEntrada,1),
	(1241,@PixProduct,@OutrosEntrada,1),
	(1263,@PixProduct,@OutrosSaida,1),
	(1264,@PixProduct,@OutrosSaida,1),
	(1265,@PixProduct,@OutrosSaida,1),
	(1385,@CambioProduct,@OutrosEntrada,1),
	(1159,@PixProduct,@OutrosSaida,1),
	(1184,@TedProduct,@OutrosEntrada,1),
	(493,@CambioProduct,@OutrosEntrada,1),
	(497,@CambioProduct,@OutrosEntrada,1),
	(1293,@FundosProduct,@OutrosSaida,1),
	(1156,@PixProduct,@OutrosEntrada,1),
	(1202,@PixProduct,@OutrosSaida,1),
	(1294,@PixProduct,@OutrosSaida,1),
	(1205,@TedProduct,@OutrosEntrada,1),
	(1415,@CambioProduct,@OutrosSaida,1),
	(1456,@CambioProduct,@OutrosSaida,1),
	(1396,@FundosProduct,@OutrosEntrada,1),
	(1248,@PixProduct,@OutrosSaida,1),
	(1494,@PixProduct,@OutrosEntrada,1),
	(1099,@TedProduct,@OutrosEntrada,1),
	(1386,@CambioProduct,@OutrosSaida,1),
	(1399,@CambioProduct,@OutrosEntrada,1),
	(1427,@CambioProduct,@OutrosSaida,1),
	(1284,@FundosProduct,@OutrosSaida,1),
	(1126,@PixProduct,@OutrosEntrada,1),
	(1129,@PixProduct,@OutrosSaida,1),
	(1189,@PixProduct,@OutrosEntrada,1),
	(1194,@PixProduct,@OutrosEntrada,1),
	(1501,@PixProduct,@OutrosSaida,1),
	(1502,@PixProduct,@OutrosEntrada,1),
	(1273,@TedProduct,@OutrosEntrada,1),
	(491,@CambioProduct,@OutrosSaida,1),
	(1218,@CambioProduct,@OutrosSaida,1),
	(1281,@CambioProduct,@OutrosSaida,1),
	(1330,@CambioProduct,@OutrosSaida,1),
	(1093,@CartaoDebitoProduct,@OutrosEntrada,1),
	(1313,@CartaoDebitoProduct,@OutrosSaida,1),
	(1466,@PagamentosProduct,@ContasRecorrentes,1),
	(1051,@PixProduct,@OutrosSaida,1),
	(1053,@PixProduct,@OutrosSaida,1),
	(1231,@PixProduct,@OutrosEntrada,1),
	(1337,@PixProduct,@OutrosSaida,1),
	(1375,@PixProduct,@OutrosSaida,1),
	(1414,@PixProduct,@OutrosEntrada,1),
	(1428,@PixProduct,@OutrosEntrada,1),
	(1316,@PrevidenciaProduct,@OutrosSaida,1),
	(1390,@PrevidenciaProduct,@OutrosSaida,1),
	(1491,@TedProduct,@OutrosEntrada,1),
	(1426,@CambioProduct,@OutrosEntrada,1),
	(1455,@CambioProduct,@OutrosSaida,1),
	(1467,@CambioProduct,@OutrosSaida,1),
	(1482,@CambioProduct,@OutrosEntrada,1),
	(1349,@CartaoDebitoProduct,@OutrosSaida,1),
	(1343,@PagamentosProduct,@Cartao,1),
	(1362,@PagamentosProduct,@OutrosEntrada,1),
	(1393,@PagamentosProduct,@OutrosEntrada,1),
	(1037,@PixProduct,@OutrosEntrada,1),
	(1038,@PixProduct,@OutrosEntrada,1),
	(1216,@PixProduct,@OutrosEntrada,1),
	(1324,@PixProduct,@OutrosSaida,1),
	(1348,@PixProduct,@OutrosEntrada,1),
	(1417,@PixProduct,@OutrosEntrada,1),
	(1418,@PixProduct,@OutrosEntrada,1),
	(1425,@PixProduct,@OutrosEntrada,1),
	(1465,@PixProduct,@OutrosEntrada,1),
	(1338,@TedProduct,@TransferenciasEntrada,1),
	(1371,@TedProduct,@OutrosSaida,1),
	(1377,@TedProduct,@OutrosEntrada,1),
	(1378,@TedProduct,@OutrosSaida,1),
	(1488,@TedProduct,@OutrosEntrada,1),
	(1490,@TedProduct,@OutrosSaida,1),
	(1492,@TedProduct,@OutrosSaida,1),
	(1495,@TedProduct,@OutrosSaida,1),
	(1496,@TedProduct,@OutrosEntrada,1),
	(1505,@BloqueiosProduct,@OutrosSaida,1),
	(1481,@CambioProduct,@OutrosSaida,1),
	(1029,@CartaoDebitoProduct,@OutrosSaida,1),
	(1503,@FundosProduct,@OutrosEntrada,1),
	(1105,@PagamentosProduct,@OutrosEntrada,1),
	(1139,@PagamentosProduct,@OutrosEntrada,1),
	(1215,@PagamentosProduct,@OutrosEntrada,1),
	(1421,@PagamentosProduct,@OutrosEntrada,1),
	(573,@PixProduct,@OutrosSaida,1),
	(1097,@PixProduct,@OutrosEntrada,1),
	(1144,@PixProduct,@OutrosEntrada,1),
	(1155,@PixProduct,@OutrosEntrada,1),
	(1158,@PixProduct,@OutrosEntrada,1),
	(1169,@PixProduct,@OutrosSaida,1),
	(1219,@PixProduct,@OutrosSaida,1),
	(1228,@PixProduct,@OutrosSaida,1),
	(1277,@PixProduct,@OutrosEntrada,1),
	(1278,@PixProduct,@OutrosSaida,1),
	(1300,@PixProduct,@OutrosSaida,1),
	(1307,@PixProduct,@OutrosEntrada,1),
	(1347,@PixProduct,@OutrosSaida,1),
	(1359,@PixProduct,@OutrosSaida,1),
	(1382,@PixProduct,@OutrosSaida,1),
	(1383,@PixProduct,@OutrosEntrada,1),
	(1413,@PixProduct,@OutrosSaida,1),
	(1416,@PixProduct,@OutrosSaida,1),
	(1420,@PixProduct,@OutrosEntrada,1),
	(1422,@PixProduct,@OutrosEntrada,1),
	(1437,@PixProduct,@OutrosSaida,1),
	(1450,@PixProduct,@OutrosEntrada,1),
	(1454,@PixProduct,@OutrosSaida,1),
	(1457,@PixProduct,@OutrosEntrada,1),
	(1459,@PixProduct,@OutrosSaida,1),
	(1461,@PixProduct,@OutrosEntrada,1),
	(1464,@PixProduct,@OutrosSaida,1),
	(1484,@PixProduct,@OutrosSaida,1),
	(1489,@PixProduct,@OutrosEntrada,1),
	(1389,@PrevidenciaProduct,@OutrosEntrada,1),
	(1331,@TedProduct,@OutrosSaida,1),
	(1332,@TedProduct,@OutrosEntrada,1),
	(1333,@TedProduct,@OutrosEntrada,1),
	(1504,@TedProduct,@OutrosEntrada,1);
END
GO

CREATE TABLE [serving].[BackfillWindow] (
    Id            INT IDENTITY(1,1) PRIMARY KEY,
    StartDate     DATETIME2(3) NOT NULL,
    EndDate       DATETIME2(3) NOT NULL,
    Status        VARCHAR(20)  NOT NULL, -- Pending, Running, Done, Failed
    RowsRead      BIGINT       NULL,
    RowsInserted  BIGINT       NULL,
    LastError     NVARCHAR(MAX) NULL,
    LastUpdatedAt DATETIME2(3) NOT NULL CONSTRAINT DF_BackfillWindow_LastUpdatedAt DEFAULT SYSUTCDATETIME()
);
GO

CREATE OR ALTER PROCEDURE [serving].[sp_BackfillWindow_ClaimNext]
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH cte AS (
        SELECT TOP (1) *
        FROM [serving].[BackfillWindow]
        WHERE Status = 'Pending'
        ORDER BY StartDate
    )
    UPDATE cte
    SET Status        = 'Running',
        LastUpdatedAt = SYSUTCDATETIME()
    OUTPUT inserted.*;
END
GO

CREATE OR ALTER PROCEDURE [serving].[sp_BackfillWindow_MarkDone]
    @Id            INT,
    @RowsRead      BIGINT,
    @RowsInserted  BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE [serving].[BackfillWindow]
    SET Status        = 'Done',
        RowsRead      = @RowsRead,
        RowsInserted  = @RowsInserted,
        LastError     = NULL,
        LastUpdatedAt = SYSUTCDATETIME()
    WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE [serving].[sp_BackfillWindow_MarkFailed]
    @Id        INT,
    @Error     NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE [serving].[BackfillWindow]
    SET Status        = 'Failed',
        LastError     = @Error,
        LastUpdatedAt = SYSUTCDATETIME()
    WHERE Id = @Id;
END
GO

CREATE TYPE serving.DimClientKey AS TABLE
(
    TradingAccount BIGINT NOT NULL,
    Brand          SMALLINT NOT NULL
);
GO

CREATE OR ALTER PROCEDURE serving.sp_DimClient_BulkGetOrCreate
    @Clients serving.DimClientKey READONLY
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH DistinctClients AS (
        SELECT DISTINCT TradingAccount, Brand
        FROM @Clients
    )
    INSERT INTO serving.DimClient (TradingAccount, Brand)
    SELECT
        dc.TradingAccount,
        dc.Brand
    FROM DistinctClients dc
    LEFT JOIN serving.DimClient d WITH (UPDLOCK, HOLDLOCK)
        ON d.TradingAccount = dc.TradingAccount
       AND d.Brand          = dc.Brand
    WHERE d.ClientId IS NULL;

    SELECT c.TradingAccount,
           c.Brand,
           c.ClientId
    FROM serving.DimClient c
    WHERE EXISTS (
        SELECT 1
        FROM @Clients k
        WHERE k.TradingAccount = c.TradingAccount
          AND k.Brand          = c.Brand
    );
END
GO

-- Staging para FactTransaction
CREATE TABLE [serving].[FactTransaction_Staging] (
    BackfillWindowId      INT               NOT NULL,
    OriginalTransactionId UNIQUEIDENTIFIER  NOT NULL,
    EntryId               BIGINT            NOT NULL,
    ClientId              INT               NOT NULL,
    DateId                INT               NOT NULL,
    ProductId             INT               NOT NULL,
    CategoryId            INT               NOT NULL,
    Amount                DECIMAL(18,2)     NOT NULL,
    Description           VARCHAR(255)      NULL,
    OccurredAt            DATETIME2(3)      NOT NULL
);
GO

CREATE NONCLUSTERED INDEX IX_FactTransaction_Staging_Window_Transaction
ON serving.FactTransaction_Staging (BackfillWindowId);
GO

CREATE OR ALTER PROCEDURE [serving].[sp_FactTransaction_MergeFromStaging]
    @BackfillWindowId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Inserted BIGINT = 0;

    BEGIN TRAN;

    ;WITH Candidates AS (
        SELECT
            s.BackfillWindowId,
            s.OriginalTransactionId,  -- valor original vindo da staging (renomeado)
            s.EntryId,
            s.ClientId,
            s.DateId,
            s.ProductId,
            s.CategoryId,
            s.Amount,
            s.Description,
            s.OccurredAt
        FROM serving.FactTransaction_Staging s
        WHERE s.BackfillWindowId = @BackfillWindowId
    ),
    Filtered AS (
        SELECT c.*
        FROM Candidates c
        WHERE NOT EXISTS (
            SELECT 1
            FROM serving.FactTransaction fe WITH (INDEX(UX_FactTransaction_EntryId_Global), UPDLOCK, HOLDLOCK)
            WHERE fe.EntryId = c.EntryId
        )
    )
    INSERT INTO serving.FactTransaction (
        TransactionId,           -- PFM ID
        OriginalTransactionId,   -- ID original (produto/origem)
        EntryId,
        ClientId,
        DateId,
        ProductId,
        CategoryId,
        Amount,
        Description,
        OccurredAt
    )
    SELECT
        NEWID()                      AS TransactionId,         -- SEMPRE novo PFM ID
        c.OriginalTransactionId      AS OriginalTransactionId, -- SEMPRE o original vindo da staging
        c.EntryId,
        c.ClientId,
        c.DateId,
        c.ProductId,
        c.CategoryId,
        c.Amount,
        c.Description,
        c.OccurredAt
    FROM Filtered c;

    SET @Inserted = @@ROWCOUNT;

    DELETE FROM serving.FactTransaction_Staging
    WHERE BackfillWindowId = @BackfillWindowId;

    COMMIT;

    SELECT @Inserted AS RowsInserted;
END
GO