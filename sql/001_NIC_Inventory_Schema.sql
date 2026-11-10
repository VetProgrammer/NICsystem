/*
NICsystem - First SQL Server DDL Draft
Primary working source: docs/NICsystem_Proposed_Physical_Schema_Decisions_1-37.pdf. The requested .md file was unavailable; this same-basename PDF identifies itself as the current 37-decision review copy and supersedes the older schema PDF. Relevant NIC baselines were also reviewed. This draft has not been executed.

SETTLED DECISIONS REPRESENTED
- Complete immutable PO-version snapshots and versioned lines; same-PO/version FK integrity.
- Six PO statuses, current status, and append-only status history.
- VP Finance approval before every placement; no subordinate delegation under current policy.
- Supplier contact/address snapshots, receipt disposition history, outstanding quantity resolution.
- User identities for recorded actions; separately modeled/audited user-role and role-permission assignments.
- One tracking method per catalog item initially (Quantity or Individual); combined tracking deferred.
- Separate fulfillment, inventory, ownership, movement, allocation, location, and ON-ORDER obligation concepts; ON-ORDER is explicitly rejected as a physical location code.
- Transactional inventory balance cache; history is authoritative.

FIRST-DRAFT ASSUMPTIONS
- AppUser is a local schema identity; authentication provider/login integration is undecided.
- PurchaseOrderLineEvent is a typed record for return, replacement, credit, excess delivery, and partial cancellation. Cross-event quantity reconciliation remains application work.
- SerialNumberException is a traceable authorization hook; detailed authority and exception policy are unresolved.
- Business-managed lookup tables and physical-location rows are created empty because seed data is prohibited. Their approved rows must be supplied separately before use.
-
DEFERRED APPLICATION RULES
Enforce VP Finance authority before every placement; detailed PO amendment/reapproval; the existing status policy without inventing a complete transition matrix; reconciliation of returns/replacements/credits/excess/cancellations/outstanding obligations; permission checks; active organization-role checks; serial exception authorization; subscription renewal; secure secret storage/access; accounting scope; retention/disposal.

STRUCTURAL LIMITATIONS AND REQUIRED TRANSACTIONAL RULES
BusinessEvent.EntityType/EntityId is polymorphic and has no universal ordinary FK; validate its target transactionally and link any correction to the original with BusinessEvent.CorrectsBusinessEventId plus the correct EntityType/EntityId. OrganizationRole references enforce the Supplier or ManufacturerPublisher role row, but applications must require IsActive=1 for new supplier/publisher use. Follow-up audit uses LastChangedByUserId and LastChangeReason; the application must set the actual actor/reason on each change. For every receipt or inventory operation, use one transaction for the append-only inventory transaction header/lines, current InventoryBalanceCache changes, and related ownership or allocation changes. Lock affected lot/unit, location/owner balance keys, and allocation rows in a consistent order (UPDLOCK/HOLDLOCK or serializable isolation), recompute from immutable transaction lines, prevent negative balances, and retry deadlocks/concurrency conflicts. For quantity-tracked lots, sum all current location/owner balances must be between zero and ReceivedQuantity. For individual lots, unit count must equal ReceivedQuantity at commit; the SQL trigger prevents exceeding it, and the balance cache permits only unit rows (with at most one positive balance row per unit). These cross-row totals still require serialized application enforcement. Availability must include only positive on-hand at IsAvailableLocation=1 and subtract every unreleased allocation; expired allocations remain reserved until explicitly released. The allocation trigger writes an immutable InventoryAllocationHistory row in the same DML transaction for every create/update; applications must set LastChangedByUserId, LastChangeActionCode, reason, and authorization reference accurately. Prevent over-allocation by locking the underlying eligible balance and all unreleased allocation rows in the same transaction as cache/movement updates. ExpiresAtUtc is recorded for review and does not automatically release or change allocation status; expired but unreleased quantity remains reserved.

InventoryOwnership transfers must close the prior current row and insert an effective-dated successor atomically. The application must ensure intervals for a unit do not overlap and that successor EffectiveFromUtc equals the former row's EffectiveToUtc. Require exactly one current owner per unit and reconcile current owner quantities for each quantity lot to its on-hand quantity; SQL unique indexes enforce at most one unit owner, but cannot require one, check historical interval overlap, or reconcile lot totals. Current PO status changes must update PurchaseOrder.CurrentStatusCode and append PurchaseOrderStatusHistory in one transaction while locking/checking the PO row (including RowVersion or equivalent concurrency validation); validate the already-approved transition/authorization policy in application logic. ReceiptDisposition updates automatically append matching immutable history in the same DML transaction; the application must provide the actual actor/reason/evidence and commit the disposition, inventory movements, ownership, and cache changes together. The six status lookup rows are intentionally not seeded, so PO records cannot yet reference a status.

No connection, execution, migration, or application-code change is part of this script.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE TABLE dbo.AppUser
(
    UserId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_AppUser PRIMARY KEY,
    UserName nvarchar(200) NOT NULL,
    DisplayName nvarchar(200) NOT NULL,
    Email nvarchar(320) NULL,
    IsActive bit NOT NULL CONSTRAINT DF_AppUser_IsActive DEFAULT (1),
    CreatedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_AppUser_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
    RowVersion rowversion NOT NULL,
    CONSTRAINT UQ_AppUser_UserName UNIQUE (UserName)
);
GO
CREATE TABLE dbo.AppRole
(
    RoleId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_AppRole PRIMARY KEY,
    RoleCode varchar(50) NOT NULL,
    DisplayName nvarchar(200) NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_AppRole_IsActive DEFAULT (1),
    CONSTRAINT UQ_AppRole_Code UNIQUE (RoleCode)
);
GO
CREATE TABLE dbo.AppPermission
(
    PermissionId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_AppPermission PRIMARY KEY,
    PermissionCode varchar(100) NOT NULL,
    DisplayName nvarchar(200) NOT NULL,
    Description nvarchar(1000) NULL,
    CONSTRAINT UQ_AppPermission_Code UNIQUE (PermissionCode)
);
GO
CREATE TABLE dbo.AppUserRole
(
    AppUserRoleId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_AppUserRole PRIMARY KEY,
    UserId int NOT NULL,
    RoleId int NOT NULL,
    AssignedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_AppUserRole_AssignedAtUtc DEFAULT (SYSUTCDATETIME()),
    AssignedByUserId int NOT NULL,
    RevokedAtUtc datetime2(0) NULL,
    RevokedByUserId int NULL,
    ChangeReason nvarchar(1000) NULL,
    RowVersion rowversion NOT NULL,
    CONSTRAINT FK_AppUserRole_User FOREIGN KEY (UserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT FK_AppUserRole_Role FOREIGN KEY (RoleId) REFERENCES dbo.AppRole(RoleId),
    CONSTRAINT FK_AppUserRole_AssignedBy FOREIGN KEY (AssignedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT FK_AppUserRole_RevokedBy FOREIGN KEY (RevokedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT CK_AppUserRole_Date CHECK (RevokedAtUtc IS NULL OR RevokedAtUtc >= AssignedAtUtc)
);
GO
CREATE UNIQUE INDEX UX_AppUserRole_Active ON dbo.AppUserRole(UserId, RoleId) WHERE RevokedAtUtc IS NULL;
GO
CREATE TABLE dbo.AppUserRoleHistory
(
    AppUserRoleHistoryId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_AppUserRoleHistory PRIMARY KEY,
    AppUserRoleId bigint NOT NULL,
    ActionCode varchar(20) NOT NULL,
    OccurredAtUtc datetime2(0) NOT NULL CONSTRAINT DF_AppUserRoleHistory_Time DEFAULT (SYSUTCDATETIME()),
    ActorUserId int NOT NULL,
    Reason nvarchar(1000) NULL,
    CONSTRAINT FK_AppUserRoleHistory_Assignment FOREIGN KEY (AppUserRoleId) REFERENCES dbo.AppUserRole(AppUserRoleId),
    CONSTRAINT FK_AppUserRoleHistory_Actor FOREIGN KEY (ActorUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT CK_AppUserRoleHistory_Action CHECK (ActionCode IN ('Granted', 'Revoked', 'Corrected'))
);
GO
CREATE TABLE dbo.AppRolePermission
(
    AppRolePermissionId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_AppRolePermission PRIMARY KEY,
    RoleId int NOT NULL,
    PermissionId int NOT NULL,
    AssignedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_AppRolePermission_AssignedAtUtc DEFAULT (SYSUTCDATETIME()),
    AssignedByUserId int NOT NULL,
    RevokedAtUtc datetime2(0) NULL,
    RevokedByUserId int NULL,
    ChangeReason nvarchar(1000) NULL,
    CONSTRAINT FK_AppRolePermission_Role FOREIGN KEY (RoleId) REFERENCES dbo.AppRole(RoleId),
    CONSTRAINT FK_AppRolePermission_Permission FOREIGN KEY (PermissionId) REFERENCES dbo.AppPermission(PermissionId),
    CONSTRAINT FK_AppRolePermission_AssignedBy FOREIGN KEY (AssignedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT FK_AppRolePermission_RevokedBy FOREIGN KEY (RevokedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT CK_AppRolePermission_Date CHECK (RevokedAtUtc IS NULL OR RevokedAtUtc >= AssignedAtUtc)
);
GO
CREATE UNIQUE INDEX UX_AppRolePermission_Active ON dbo.AppRolePermission(RoleId, PermissionId) WHERE RevokedAtUtc IS NULL;
GO
CREATE TABLE dbo.AppRolePermissionHistory
(
    AppRolePermissionHistoryId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_AppRolePermissionHistory PRIMARY KEY,
    AppRolePermissionId bigint NOT NULL,
    ActionCode varchar(20) NOT NULL,
    OccurredAtUtc datetime2(0) NOT NULL CONSTRAINT DF_AppRolePermissionHistory_Time DEFAULT (SYSUTCDATETIME()),
    ActorUserId int NOT NULL,
    Reason nvarchar(1000) NULL,
    CONSTRAINT FK_AppRolePermissionHistory_Assignment FOREIGN KEY (AppRolePermissionId) REFERENCES dbo.AppRolePermission(AppRolePermissionId),
    CONSTRAINT FK_AppRolePermissionHistory_Actor FOREIGN KEY (ActorUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT CK_AppRolePermissionHistory_Action CHECK (ActionCode IN ('Granted', 'Revoked', 'Corrected'))
);
GO

CREATE TABLE dbo.Organization
(
    OrganizationId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Organization PRIMARY KEY,
    Name nvarchar(200) NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_Organization_IsActive DEFAULT (1),
    Notes nvarchar(1000) NULL,
    CreatedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_Organization_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
    CreatedByUserId int NOT NULL,
    RowVersion rowversion NOT NULL,
    CONSTRAINT FK_Organization_CreatedBy FOREIGN KEY (CreatedByUserId) REFERENCES dbo.AppUser(UserId)
);
GO
CREATE TABLE dbo.OrganizationRole
(
    OrganizationRoleId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_OrganizationRole PRIMARY KEY,
    OrganizationId int NOT NULL,
    RoleCode varchar(30) NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_OrganizationRole_IsActive DEFAULT (1),
    CONSTRAINT FK_OrganizationRole_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.Organization(OrganizationId),
    CONSTRAINT UQ_OrganizationRole_Organization_Role UNIQUE (OrganizationId, RoleCode),
    CONSTRAINT CK_OrganizationRole_Code CHECK (RoleCode IN ('Supplier', 'ManufacturerPublisher'))
);
GO
CREATE TABLE dbo.SupplierContact
(
    SupplierContactId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SupplierContact PRIMARY KEY,
    SupplierOrganizationId int NOT NULL,
    ContactName nvarchar(200) NOT NULL,
    Email nvarchar(320) NULL,
    Telephone nvarchar(50) NULL,
    IsActive bit NOT NULL CONSTRAINT DF_SupplierContact_IsActive DEFAULT (1),
    CreatedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_SupplierContact_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
    CreatedByUserId int NOT NULL,
    SupplierRoleCode varchar(30) NOT NULL CONSTRAINT DF_SupplierContact_Role DEFAULT ('Supplier'),
    CONSTRAINT FK_SupplierContact_Organization FOREIGN KEY (SupplierOrganizationId) REFERENCES dbo.Organization(OrganizationId),
    CONSTRAINT FK_SupplierContact_Role FOREIGN KEY (SupplierOrganizationId, SupplierRoleCode) REFERENCES dbo.OrganizationRole(OrganizationId, RoleCode),
    CONSTRAINT CK_SupplierContact_Role CHECK (SupplierRoleCode = 'Supplier'),
    CONSTRAINT FK_SupplierContact_CreatedBy FOREIGN KEY (CreatedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT UQ_SupplierContact_Id_Organization UNIQUE (SupplierContactId, SupplierOrganizationId)
);
GO
CREATE TABLE dbo.SupplierAddress
(
    SupplierAddressId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SupplierAddress PRIMARY KEY,
    SupplierOrganizationId int NOT NULL,
    AddressTypeCode varchar(30) NOT NULL,
    AddressLines nvarchar(500) NOT NULL,
    City nvarchar(100) NULL,
    Region nvarchar(100) NULL,
    PostalCode nvarchar(30) NULL,
    Country nvarchar(100) NULL,
    IsActive bit NOT NULL CONSTRAINT DF_SupplierAddress_IsActive DEFAULT (1),
    CreatedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_SupplierAddress_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
    CreatedByUserId int NOT NULL,
    SupplierRoleCode varchar(30) NOT NULL CONSTRAINT DF_SupplierAddress_Role DEFAULT ('Supplier'),
    CONSTRAINT FK_SupplierAddress_Organization FOREIGN KEY (SupplierOrganizationId) REFERENCES dbo.Organization(OrganizationId),
    CONSTRAINT FK_SupplierAddress_Role FOREIGN KEY (SupplierOrganizationId, SupplierRoleCode) REFERENCES dbo.OrganizationRole(OrganizationId, RoleCode),
    CONSTRAINT CK_SupplierAddress_Role CHECK (SupplierRoleCode = 'Supplier'),
    CONSTRAINT FK_SupplierAddress_CreatedBy FOREIGN KEY (CreatedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT UQ_SupplierAddress_Id_Organization UNIQUE (SupplierAddressId, SupplierOrganizationId)
);
GO
CREATE TABLE dbo.ItemCatalog
(
    ItemId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ItemCatalog PRIMARY KEY,
    Sku nvarchar(80) NULL,
    Name nvarchar(200) NOT NULL,
    Description nvarchar(2000) NULL,
    ItemType varchar(30) NOT NULL,
    TrackingMethod varchar(20) NOT NULL,
    UnitOfMeasure nvarchar(30) NOT NULL,
    ManufacturerPublisherOrganizationId int NULL,
    ManufacturerPublisherRoleCode varchar(30) NULL,
    IsActive bit NOT NULL CONSTRAINT DF_ItemCatalog_IsActive DEFAULT (1),
    CreatedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_ItemCatalog_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
    CreatedByUserId int NOT NULL,
    RowVersion rowversion NOT NULL,
    CONSTRAINT FK_ItemCatalog_Manufacturer FOREIGN KEY (ManufacturerPublisherOrganizationId) REFERENCES dbo.Organization(OrganizationId),
    CONSTRAINT FK_ItemCatalog_ManufacturerRole FOREIGN KEY (ManufacturerPublisherOrganizationId, ManufacturerPublisherRoleCode) REFERENCES dbo.OrganizationRole(OrganizationId, RoleCode),
    CONSTRAINT FK_ItemCatalog_CreatedBy FOREIGN KEY (CreatedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT CK_ItemCatalog_TrackingMethod CHECK (TrackingMethod IN ('Quantity', 'Individual')),
    CONSTRAINT CK_ItemCatalog_ManufacturerRole CHECK ((ManufacturerPublisherOrganizationId IS NULL AND ManufacturerPublisherRoleCode IS NULL) OR (ManufacturerPublisherOrganizationId IS NOT NULL AND ManufacturerPublisherRoleCode = 'ManufacturerPublisher')),
    CONSTRAINT UQ_ItemCatalog_Item_Manufacturer UNIQUE (ItemId, ManufacturerPublisherOrganizationId),
    CONSTRAINT UQ_ItemCatalog_Item_UOM UNIQUE (ItemId, UnitOfMeasure),
    CONSTRAINT UQ_ItemCatalog_Item_Tracking UNIQUE (ItemId, TrackingMethod)
);
GO
CREATE UNIQUE INDEX UX_ItemCatalog_Sku_NotNull ON dbo.ItemCatalog(Sku) WHERE Sku IS NOT NULL;
GO
CREATE TABLE dbo.SerialNumberException
(
    SerialNumberExceptionId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_SerialNumberException PRIMARY KEY,
    ItemId int NOT NULL,
    SerialNumber nvarchar(150) NOT NULL,
    Reason nvarchar(1000) NOT NULL,
    AuthorizedByUserId int NOT NULL,
    AuthorizedAtUtc datetime2(0) NOT NULL,
    EvidenceReference nvarchar(500) NULL,
    CONSTRAINT FK_SerialNumberException_Item FOREIGN KEY (ItemId) REFERENCES dbo.ItemCatalog(ItemId),
    CONSTRAINT FK_SerialNumberException_User FOREIGN KEY (AuthorizedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT UQ_SerialNumberException_Id_Item_Serial UNIQUE (SerialNumberExceptionId, ItemId, SerialNumber)
);
GO
CREATE TABLE dbo.InventoryLocation
(
    InventoryLocationId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_InventoryLocation PRIMARY KEY,
    Code varchar(30) NOT NULL,
    Name nvarchar(100) NOT NULL,
    IsAvailableLocation bit NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_InventoryLocation_IsActive DEFAULT (1),
    CONSTRAINT UQ_InventoryLocation_Code UNIQUE (Code),
    CONSTRAINT CK_InventoryLocation_NoOnOrder CHECK (Code <> 'ON-ORDER'),
    CONSTRAINT CK_InventoryLocation_NonAvailableAreas CHECK (Code NOT IN ('INCOMING', 'HOLD/QUARANTINE', 'MFG-DLV', 'SVC-DLV') OR IsAvailableLocation = 0)
);
GO
CREATE TABLE dbo.PurchaseOrderStatusCode
(
    StatusCode varchar(40) NOT NULL CONSTRAINT PK_PurchaseOrderStatusCode PRIMARY KEY,
    DisplayName nvarchar(50) NOT NULL,
    Definition nvarchar(300) NOT NULL,
    CONSTRAINT UQ_PurchaseOrderStatusCode_DisplayName UNIQUE (DisplayName),
    CONSTRAINT CK_PurchaseOrderStatusCode_Values CHECK (StatusCode IN
        ('Draft', 'OnOrder', 'PartiallyReceivedFulfilled', 'OnHold', 'Closed', 'Cancelled'))
);
GO
CREATE TABLE dbo.PurchaseOrder
(
    PurchaseOrderId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_PurchaseOrder PRIMARY KEY,
    PONumber nvarchar(40) NOT NULL,
    CurrentStatusCode varchar(40) NOT NULL,
    CreatedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_PurchaseOrder_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
    CreatedByUserId int NOT NULL,
    RequestedBy nvarchar(200) NOT NULL,
    DepartmentRole nvarchar(100) NULL,
    BusinessPurpose nvarchar(1000) NULL,
    RelatedRequirement nvarchar(200) NULL,
    RowVersion rowversion NOT NULL,
    CONSTRAINT UQ_PurchaseOrder_PONumber UNIQUE (PONumber),
    CONSTRAINT FK_PurchaseOrder_Status FOREIGN KEY (CurrentStatusCode) REFERENCES dbo.PurchaseOrderStatusCode(StatusCode),
    CONSTRAINT FK_PurchaseOrder_CreatedBy FOREIGN KEY (CreatedByUserId) REFERENCES dbo.AppUser(UserId)
);
GO
CREATE TABLE dbo.PurchaseOrderVersion
(
    PurchaseOrderVersionId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_PurchaseOrderVersion PRIMARY KEY,
    PurchaseOrderId int NOT NULL,
    VersionNumber int NOT NULL,
    SupplierOrganizationId int NOT NULL,
    SupplierRoleCode varchar(30) NOT NULL CONSTRAINT DF_PurchaseOrderVersion_SupplierRole DEFAULT ('Supplier'),
    SupplierContactId int NULL,
    SupplierAddressId int NULL,
    SupplierContactNameSnapshot nvarchar(200) NULL,
    SupplierContactEmailSnapshot nvarchar(320) NULL,
    SupplierContactTelephoneSnapshot nvarchar(50) NULL,
    SupplierAddressSnapshot nvarchar(1000) NULL,
    CreatedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_PurchaseOrderVersion_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
    CreatedByUserId int NOT NULL,
    ChangeType varchar(30) NOT NULL,
    ChangeReason nvarchar(1000) NULL,
    CurrencyCode char(3) NULL,
    PaymentTerms nvarchar(500) NULL,
    DeliveryTerms nvarchar(500) NULL,
    DeliveryAddress nvarchar(500) NULL,
    RequiredDate date NULL,
    OtherTerms nvarchar(2000) NULL,
    RowVersion rowversion NOT NULL,
    CONSTRAINT FK_PurchaseOrderVersion_PO FOREIGN KEY (PurchaseOrderId) REFERENCES dbo.PurchaseOrder(PurchaseOrderId),
    CONSTRAINT FK_PurchaseOrderVersion_Supplier FOREIGN KEY (SupplierOrganizationId) REFERENCES dbo.Organization(OrganizationId),
    CONSTRAINT FK_PurchaseOrderVersion_SupplierRole FOREIGN KEY (SupplierOrganizationId, SupplierRoleCode) REFERENCES dbo.OrganizationRole(OrganizationId, RoleCode),
    CONSTRAINT FK_PurchaseOrderVersion_Contact FOREIGN KEY (SupplierContactId, SupplierOrganizationId) REFERENCES dbo.SupplierContact(SupplierContactId, SupplierOrganizationId),
    CONSTRAINT FK_PurchaseOrderVersion_Address FOREIGN KEY (SupplierAddressId, SupplierOrganizationId) REFERENCES dbo.SupplierAddress(SupplierAddressId, SupplierOrganizationId),
    CONSTRAINT FK_PurchaseOrderVersion_CreatedBy FOREIGN KEY (CreatedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT UQ_PurchaseOrderVersion_PO_Version UNIQUE (PurchaseOrderId, VersionNumber),
    CONSTRAINT UQ_PurchaseOrderVersion_Id_PO UNIQUE (PurchaseOrderVersionId, PurchaseOrderId),
    CONSTRAINT CK_PurchaseOrderVersion_SupplierRole CHECK (SupplierRoleCode = 'Supplier'),
    CONSTRAINT CK_PurchaseOrderVersion_Number CHECK (VersionNumber > 0),
    CONSTRAINT CK_PurchaseOrderVersion_ChangeType CHECK (ChangeType IN ('Original', 'AdministrativeCorrection', 'CommercialAmendment'))
);
GO
CREATE INDEX IX_PurchaseOrderVersion_Supplier_Created ON dbo.PurchaseOrderVersion(SupplierOrganizationId, CreatedAtUtc);
GO
CREATE TABLE dbo.PurchaseOrderLine
(
    PurchaseOrderLineId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_PurchaseOrderLine PRIMARY KEY,
    PurchaseOrderId int NOT NULL,
    LineNumber int NOT NULL,
    CONSTRAINT FK_PurchaseOrderLine_PO FOREIGN KEY (PurchaseOrderId) REFERENCES dbo.PurchaseOrder(PurchaseOrderId),
    CONSTRAINT UQ_PurchaseOrderLine_PO_Line UNIQUE (PurchaseOrderId, LineNumber),
    CONSTRAINT UQ_PurchaseOrderLine_Id_PO UNIQUE (PurchaseOrderLineId, PurchaseOrderId),
    CONSTRAINT CK_PurchaseOrderLine_Number CHECK (LineNumber > 0)
);
GO
CREATE TABLE dbo.PurchaseOrderLineVersion
(
    PurchaseOrderLineVersionId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_PurchaseOrderLineVersion PRIMARY KEY,
    PurchaseOrderId int NOT NULL,
    PurchaseOrderVersionId int NOT NULL,
    PurchaseOrderLineId int NOT NULL,
    ItemId int NULL,
    -- Snapshot the PO-line manufacturer/publisher required by PO Record Specification 1-4 and Guidelines 1-3.
    ManufacturerPublisherOrganizationIdSnapshot int NULL,
    ManufacturerPublisherRoleCodeSnapshot varchar(30) NULL,
    ManufacturerPublisherNameSnapshot nvarchar(200) NULL,
    Description nvarchar(2000) NOT NULL,
    Specifications nvarchar(2000) NULL,
    PurchaseType varchar(40) NOT NULL,
    Quantity decimal(18,4) NOT NULL,
    UnitOfMeasure nvarchar(30) NOT NULL,
    UnitPrice decimal(19,4) NULL,
    IntendedUse nvarchar(100) NULL,
    ExpectedOwnershipType varchar(30) NULL,
    LicenseTerm nvarchar(200) NULL,
    CommercialTerms nvarchar(1000) NULL,
    CONSTRAINT FK_PurchaseOrderLineVersion_Version FOREIGN KEY (PurchaseOrderVersionId, PurchaseOrderId) REFERENCES dbo.PurchaseOrderVersion(PurchaseOrderVersionId, PurchaseOrderId),
    CONSTRAINT FK_PurchaseOrderLineVersion_Line FOREIGN KEY (PurchaseOrderLineId, PurchaseOrderId) REFERENCES dbo.PurchaseOrderLine(PurchaseOrderLineId, PurchaseOrderId),
    CONSTRAINT FK_PurchaseOrderLineVersion_Item FOREIGN KEY (ItemId) REFERENCES dbo.ItemCatalog(ItemId),
    CONSTRAINT FK_PurchaseOrderLineVersion_Item_UOM FOREIGN KEY (ItemId, UnitOfMeasure) REFERENCES dbo.ItemCatalog(ItemId, UnitOfMeasure),
    CONSTRAINT FK_PurchaseOrderLineVersion_ManufacturerSnapshot FOREIGN KEY (ManufacturerPublisherOrganizationIdSnapshot) REFERENCES dbo.Organization(OrganizationId),
    CONSTRAINT FK_PurchaseOrderLineVersion_ManufacturerRoleSnapshot FOREIGN KEY (ManufacturerPublisherOrganizationIdSnapshot, ManufacturerPublisherRoleCodeSnapshot) REFERENCES dbo.OrganizationRole(OrganizationId, RoleCode),
    CONSTRAINT UQ_PurchaseOrderLineVersion_Version_Line UNIQUE (PurchaseOrderVersionId, PurchaseOrderLineId),
    CONSTRAINT UQ_PurchaseOrderLineVersion_Exact UNIQUE (PurchaseOrderLineVersionId, PurchaseOrderVersionId, PurchaseOrderId, PurchaseOrderLineId),
    CONSTRAINT UQ_PurchaseOrderLineVersion_Item_UOM UNIQUE (PurchaseOrderLineVersionId, ItemId, UnitOfMeasure),
    CONSTRAINT CK_PurchaseOrderLineVersion_ManufacturerRole CHECK ((ManufacturerPublisherOrganizationIdSnapshot IS NULL AND ManufacturerPublisherRoleCodeSnapshot IS NULL) OR (ManufacturerPublisherOrganizationIdSnapshot IS NOT NULL AND ManufacturerPublisherRoleCodeSnapshot = 'ManufacturerPublisher')),
    CONSTRAINT CK_PurchaseOrderLineVersion_Quantity CHECK (Quantity > 0),
    CONSTRAINT CK_PurchaseOrderLineVersion_Price CHECK (UnitPrice IS NULL OR UnitPrice >= 0)
);
GO
CREATE INDEX IX_PurchaseOrderLineVersion_Version_Line ON dbo.PurchaseOrderLineVersion(PurchaseOrderVersionId, PurchaseOrderLineId);
GO
CREATE TABLE dbo.ApprovalDecision
(
    ApprovalDecisionId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ApprovalDecision PRIMARY KEY,
    PurchaseOrderId int NOT NULL,
    PurchaseOrderVersionId int NULL,
    ActionType varchar(40) NOT NULL,
    DecisionCode varchar(30) NOT NULL,
    ApproverUserId int NOT NULL,
    ApproverNameSnapshot nvarchar(200) NOT NULL,
    ApproverRoleSnapshot nvarchar(100) NOT NULL,
    DecisionAtUtc datetime2(0) NOT NULL CONSTRAINT DF_ApprovalDecision_Time DEFAULT (SYSUTCDATETIME()),
    EvidenceReference nvarchar(500) NULL,
    Conditions nvarchar(1000) NULL,
    Notes nvarchar(1000) NULL,
    CONSTRAINT FK_ApprovalDecision_PO FOREIGN KEY (PurchaseOrderId) REFERENCES dbo.PurchaseOrder(PurchaseOrderId),
    CONSTRAINT FK_ApprovalDecision_Version FOREIGN KEY (PurchaseOrderVersionId, PurchaseOrderId) REFERENCES dbo.PurchaseOrderVersion(PurchaseOrderVersionId, PurchaseOrderId),
    CONSTRAINT FK_ApprovalDecision_Approver FOREIGN KEY (ApproverUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT UQ_ApprovalDecision_Id_PO UNIQUE (ApprovalDecisionId, PurchaseOrderId),
    CONSTRAINT UQ_ApprovalDecision_Id_PO_Version UNIQUE (ApprovalDecisionId, PurchaseOrderId, PurchaseOrderVersionId),
    CONSTRAINT CK_ApprovalDecision_Action CHECK (ActionType IN ('CommitmentApproval', 'Cancel', 'CloseWithOutstanding', 'OtherAuthorization'))
);
GO
CREATE INDEX IX_ApprovalDecision_PO_Action_Time ON dbo.ApprovalDecision(PurchaseOrderId, ActionType, DecisionAtUtc);
GO
CREATE TABLE dbo.OrderPlacement
(
    OrderPlacementId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_OrderPlacement PRIMARY KEY,
    PurchaseOrderId int NOT NULL,
    PurchaseOrderVersionId int NOT NULL,
    PlacedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_OrderPlacement_Time DEFAULT (SYSUTCDATETIME()),
    PlacedByUserId int NOT NULL,
    Method varchar(30) NULL,
    SupplierConfirmationReference nvarchar(200) NULL,
    CommunicationReference nvarchar(500) NULL,
    ConfirmedDeliveryDate date NULL,
    Notes nvarchar(1000) NULL,
    CONSTRAINT FK_OrderPlacement_Version FOREIGN KEY (PurchaseOrderVersionId, PurchaseOrderId) REFERENCES dbo.PurchaseOrderVersion(PurchaseOrderVersionId, PurchaseOrderId),
    CONSTRAINT FK_OrderPlacement_User FOREIGN KEY (PlacedByUserId) REFERENCES dbo.AppUser(UserId)
);
GO
CREATE INDEX IX_OrderPlacement_Version_Time ON dbo.OrderPlacement(PurchaseOrderVersionId, PlacedAtUtc);
GO
CREATE TABLE dbo.SupportingDocument
(
    SupportingDocumentId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SupportingDocument PRIMARY KEY,
    PurchaseOrderId int NOT NULL,
    PurchaseOrderVersionId int NULL,
    DocumentType varchar(40) NOT NULL,
    DisplayName nvarchar(200) NOT NULL,
    ExternalReference nvarchar(1000) NOT NULL,
    AddedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_SupportingDocument_Time DEFAULT (SYSUTCDATETIME()),
    AddedByUserId int NOT NULL,
    CONSTRAINT FK_SupportingDocument_PO FOREIGN KEY (PurchaseOrderId) REFERENCES dbo.PurchaseOrder(PurchaseOrderId),
    CONSTRAINT FK_SupportingDocument_Version FOREIGN KEY (PurchaseOrderVersionId, PurchaseOrderId) REFERENCES dbo.PurchaseOrderVersion(PurchaseOrderVersionId, PurchaseOrderId),
    CONSTRAINT FK_SupportingDocument_User FOREIGN KEY (AddedByUserId) REFERENCES dbo.AppUser(UserId)
);
GO
CREATE TABLE dbo.FulfillmentEvent
(
    FulfillmentEventId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_FulfillmentEvent PRIMARY KEY,
    PurchaseOrderId int NOT NULL,
    PurchaseOrderVersionId int NOT NULL,
    EventType varchar(20) NOT NULL,
    OccurredAtUtc datetime2(0) NOT NULL,
    RecordedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_FulfillmentEvent_RecordedAtUtc DEFAULT (SYSUTCDATETIME()),
    RecordedByUserId int NOT NULL,
    RecordedByNameSnapshot nvarchar(200) NULL,
    SupplierReference nvarchar(200) NULL,
    LocationId int NULL,
    EvidenceReference nvarchar(500) NULL,
    Notes nvarchar(1000) NULL,
    CONSTRAINT FK_FulfillmentEvent_Version FOREIGN KEY (PurchaseOrderVersionId, PurchaseOrderId) REFERENCES dbo.PurchaseOrderVersion(PurchaseOrderVersionId, PurchaseOrderId),
    CONSTRAINT FK_FulfillmentEvent_User FOREIGN KEY (RecordedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT FK_FulfillmentEvent_Location FOREIGN KEY (LocationId) REFERENCES dbo.InventoryLocation(InventoryLocationId),
    CONSTRAINT UQ_FulfillmentEvent_Id_PO_Version UNIQUE (FulfillmentEventId, PurchaseOrderId, PurchaseOrderVersionId),
    CONSTRAINT UQ_FulfillmentEvent_Id_PO_Version_Type UNIQUE (FulfillmentEventId, PurchaseOrderId, PurchaseOrderVersionId, EventType),
    CONSTRAINT CK_FulfillmentEvent_Type CHECK (EventType IN ('PhysicalReceipt', 'DigitalFulfillment'))
);
GO
CREATE INDEX IX_FulfillmentEvent_Occurred_Type ON dbo.FulfillmentEvent(OccurredAtUtc, EventType);
GO
CREATE TABLE dbo.FulfillmentEventLine
(
    FulfillmentEventLineId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_FulfillmentEventLine PRIMARY KEY,
    FulfillmentEventId bigint NOT NULL,
    PurchaseOrderId int NOT NULL,
    PurchaseOrderVersionId int NOT NULL,
    PurchaseOrderLineId int NOT NULL,
    PurchaseOrderLineVersionId int NOT NULL,
    ItemId int NULL,
    EventType varchar(20) NOT NULL,
    Quantity decimal(18,4) NOT NULL,
    UnitOfMeasure nvarchar(30) NOT NULL,
    LineReference nvarchar(200) NULL,
    CONSTRAINT FK_FulfillmentEventLine_Event FOREIGN KEY (FulfillmentEventId, PurchaseOrderId, PurchaseOrderVersionId) REFERENCES dbo.FulfillmentEvent(FulfillmentEventId, PurchaseOrderId, PurchaseOrderVersionId),
    CONSTRAINT FK_FulfillmentEventLine_EventType FOREIGN KEY (FulfillmentEventId, PurchaseOrderId, PurchaseOrderVersionId, EventType) REFERENCES dbo.FulfillmentEvent(FulfillmentEventId, PurchaseOrderId, PurchaseOrderVersionId, EventType),
    CONSTRAINT FK_FulfillmentEventLine_PO_Line FOREIGN KEY (PurchaseOrderLineId, PurchaseOrderId) REFERENCES dbo.PurchaseOrderLine(PurchaseOrderLineId, PurchaseOrderId),
    CONSTRAINT FK_FulfillmentEventLine_VersionedLine FOREIGN KEY (PurchaseOrderLineVersionId, PurchaseOrderVersionId, PurchaseOrderId, PurchaseOrderLineId) REFERENCES dbo.PurchaseOrderLineVersion(PurchaseOrderLineVersionId, PurchaseOrderVersionId, PurchaseOrderId, PurchaseOrderLineId),
    CONSTRAINT FK_FulfillmentEventLine_Item_UOM FOREIGN KEY (PurchaseOrderLineVersionId, ItemId, UnitOfMeasure) REFERENCES dbo.PurchaseOrderLineVersion(PurchaseOrderLineVersionId, ItemId, UnitOfMeasure),
    CONSTRAINT UQ_FulfillmentEventLine_Id_PO_Line UNIQUE (FulfillmentEventLineId, PurchaseOrderId, PurchaseOrderLineId),
    CONSTRAINT UQ_FulfillmentEventLine_Exact UNIQUE (FulfillmentEventLineId, PurchaseOrderId, PurchaseOrderVersionId, PurchaseOrderLineId, PurchaseOrderLineVersionId),
    CONSTRAINT UQ_FulfillmentEventLine_SourceItemUOMType UNIQUE (FulfillmentEventLineId, ItemId, UnitOfMeasure, EventType),
    CONSTRAINT CK_FulfillmentEventLine_Quantity CHECK (Quantity > 0)
);
GO
CREATE INDEX IX_FulfillmentEventLine_PO_Line ON dbo.FulfillmentEventLine(PurchaseOrderLineId, PurchaseOrderVersionId);
GO
CREATE TABLE dbo.ReceiptDisposition
(
    ReceiptDispositionId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ReceiptDisposition PRIMARY KEY,
    FulfillmentEventLineId bigint NOT NULL,
    AcceptedQuantity decimal(18,4) NOT NULL CONSTRAINT DF_ReceiptDisposition_Accepted DEFAULT (0),
    HeldQuantity decimal(18,4) NOT NULL CONSTRAINT DF_ReceiptDisposition_Held DEFAULT (0),
    RejectedQuantity decimal(18,4) NOT NULL CONSTRAINT DF_ReceiptDisposition_Rejected DEFAULT (0),
    UpdatedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_ReceiptDisposition_UpdatedAtUtc DEFAULT (SYSUTCDATETIME()),
    UpdatedByUserId int NOT NULL,
    LastChangeReason nvarchar(1000) NULL,
    LastChangeEvidenceReference nvarchar(500) NULL,
    RowVersion rowversion NOT NULL,
    CONSTRAINT FK_ReceiptDisposition_Line FOREIGN KEY (FulfillmentEventLineId) REFERENCES dbo.FulfillmentEventLine(FulfillmentEventLineId),
    CONSTRAINT FK_ReceiptDisposition_User FOREIGN KEY (UpdatedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT UQ_ReceiptDisposition_Line UNIQUE (FulfillmentEventLineId),
    CONSTRAINT UQ_ReceiptDisposition_Id_Line UNIQUE (ReceiptDispositionId, FulfillmentEventLineId),
    CONSTRAINT CK_ReceiptDisposition_Quantities CHECK (AcceptedQuantity >= 0 AND HeldQuantity >= 0 AND RejectedQuantity >= 0)
);
GO
CREATE TABLE dbo.ReceiptDispositionHistory
(
    ReceiptDispositionHistoryId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ReceiptDispositionHistory PRIMARY KEY,
    ReceiptDispositionId bigint NOT NULL,
    FulfillmentEventLineId bigint NOT NULL,
    PreviousAcceptedQuantity decimal(18,4) NULL,
    NewAcceptedQuantity decimal(18,4) NOT NULL,
    PreviousHeldQuantity decimal(18,4) NULL,
    NewHeldQuantity decimal(18,4) NOT NULL,
    PreviousRejectedQuantity decimal(18,4) NULL,
    NewRejectedQuantity decimal(18,4) NOT NULL,
    ChangedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_ReceiptDispositionHistory_Time DEFAULT (SYSUTCDATETIME()),
    ChangedByUserId int NOT NULL,
    Reason nvarchar(1000) NULL,
    EvidenceReference nvarchar(500) NULL,
    CONSTRAINT FK_ReceiptDispositionHistory_Disposition FOREIGN KEY (ReceiptDispositionId, FulfillmentEventLineId) REFERENCES dbo.ReceiptDisposition(ReceiptDispositionId, FulfillmentEventLineId),
    CONSTRAINT FK_ReceiptDispositionHistory_User FOREIGN KEY (ChangedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT CK_ReceiptDispositionHistory_Quantities CHECK
        (NewAcceptedQuantity >= 0 AND NewHeldQuantity >= 0 AND NewRejectedQuantity >= 0 AND
         (PreviousAcceptedQuantity IS NULL OR PreviousAcceptedQuantity >= 0) AND
         (PreviousHeldQuantity IS NULL OR PreviousHeldQuantity >= 0) AND
         (PreviousRejectedQuantity IS NULL OR PreviousRejectedQuantity >= 0)),
    CONSTRAINT CK_ReceiptDispositionHistory_PreviousAllOrNone CHECK
        ((PreviousAcceptedQuantity IS NULL AND PreviousHeldQuantity IS NULL AND PreviousRejectedQuantity IS NULL) OR
         (PreviousAcceptedQuantity IS NOT NULL AND PreviousHeldQuantity IS NOT NULL AND PreviousRejectedQuantity IS NOT NULL))
);
GO
CREATE INDEX IX_ReceiptDispositionHistory_Disposition_Time ON dbo.ReceiptDispositionHistory(ReceiptDispositionId, ChangedAtUtc);
CREATE UNIQUE INDEX UX_ReceiptDispositionHistory_Initial ON dbo.ReceiptDispositionHistory(ReceiptDispositionId) WHERE PreviousAcceptedQuantity IS NULL;
GO
CREATE TABLE dbo.Discrepancy
(
    DiscrepancyId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Discrepancy PRIMARY KEY,
    FulfillmentEventLineId bigint NOT NULL,
    PurchaseOrderId int NOT NULL,
    PurchaseOrderVersionId int NOT NULL,
    PurchaseOrderLineId int NOT NULL,
    PurchaseOrderLineVersionId int NOT NULL,
    DiscrepancyType varchar(40) NOT NULL,
    Description nvarchar(2000) NOT NULL,
    AffectedQuantity decimal(18,4) NULL,
    IdentifiedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_Discrepancy_IdentifiedAtUtc DEFAULT (SYSUTCDATETIME()),
    IdentifiedByUserId int NOT NULL,
    StatusCode varchar(30) NOT NULL,
    EvidenceReference nvarchar(500) NULL,
    RowVersion rowversion NOT NULL,
    CONSTRAINT FK_Discrepancy_FulfillmentLine FOREIGN KEY (FulfillmentEventLineId, PurchaseOrderId, PurchaseOrderVersionId, PurchaseOrderLineId, PurchaseOrderLineVersionId) REFERENCES dbo.FulfillmentEventLine(FulfillmentEventLineId, PurchaseOrderId, PurchaseOrderVersionId, PurchaseOrderLineId, PurchaseOrderLineVersionId),
    CONSTRAINT FK_Discrepancy_IdentifiedBy FOREIGN KEY (IdentifiedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT UQ_Discrepancy_Id_PO_Line UNIQUE (DiscrepancyId, PurchaseOrderId, PurchaseOrderLineId),
    CONSTRAINT UQ_Discrepancy_Id_LineVersion UNIQUE (DiscrepancyId, FulfillmentEventLineId, PurchaseOrderId, PurchaseOrderVersionId),
    CONSTRAINT CK_Discrepancy_AffectedQuantity CHECK (AffectedQuantity IS NULL OR AffectedQuantity >= 0)
);
GO
CREATE INDEX IX_Discrepancy_Status_Time ON dbo.Discrepancy(StatusCode, IdentifiedAtUtc);
GO
CREATE TABLE dbo.DiscrepancyResolution
(
    DiscrepancyResolutionId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DiscrepancyResolution PRIMARY KEY,
    DiscrepancyId int NOT NULL,
    FulfillmentEventLineId bigint NOT NULL,
    PurchaseOrderId int NOT NULL,
    PurchaseOrderVersionId int NOT NULL,
    ResolutionType varchar(40) NOT NULL,
    Quantity decimal(18,4) NULL,
    ResolvedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_DiscrepancyResolution_Time DEFAULT (SYSUTCDATETIME()),
    ResolvedByUserId int NOT NULL,
    AuthorizationDecisionId int NULL,
    Reason nvarchar(1000) NULL,
    EvidenceReference nvarchar(500) NULL,
    CONSTRAINT FK_DiscrepancyResolution_Discrepancy FOREIGN KEY (DiscrepancyId, FulfillmentEventLineId, PurchaseOrderId, PurchaseOrderVersionId) REFERENCES dbo.Discrepancy(DiscrepancyId, FulfillmentEventLineId, PurchaseOrderId, PurchaseOrderVersionId),
    CONSTRAINT FK_DiscrepancyResolution_Authorization FOREIGN KEY (AuthorizationDecisionId, PurchaseOrderId, PurchaseOrderVersionId) REFERENCES dbo.ApprovalDecision(ApprovalDecisionId, PurchaseOrderId, PurchaseOrderVersionId),
    CONSTRAINT FK_DiscrepancyResolution_User FOREIGN KEY (ResolvedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT CK_DiscrepancyResolution_Quantity CHECK (Quantity IS NULL OR Quantity >= 0)
);
GO
CREATE TABLE dbo.FollowUpAssignment
(
    FollowUpAssignmentId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_FollowUpAssignment PRIMARY KEY,
    PurchaseOrderId int NULL,
    DiscrepancyId int NULL,
    DepartmentOrRole nvarchar(100) NOT NULL,
    AssignedUserId int NULL,
    AssignedPersonSnapshot nvarchar(200) NULL,
    StatusCode varchar(30) NOT NULL,
    AssignedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_FollowUpAssignment_AssignedAtUtc DEFAULT (SYSUTCDATETIME()),
    AssignedByUserId int NOT NULL,
    LastChangedByUserId int NOT NULL,
    LastChangeReason nvarchar(1000) NULL,
    NextAction nvarchar(1000) NULL,
    DueDate date NULL,
    ResolvedAtUtc datetime2(0) NULL,
    Resolution nvarchar(1000) NULL,
    RowVersion rowversion NOT NULL,
    CONSTRAINT FK_FollowUpAssignment_PO FOREIGN KEY (PurchaseOrderId) REFERENCES dbo.PurchaseOrder(PurchaseOrderId),
    CONSTRAINT FK_FollowUpAssignment_Discrepancy FOREIGN KEY (DiscrepancyId) REFERENCES dbo.Discrepancy(DiscrepancyId),
    CONSTRAINT FK_FollowUpAssignment_Assignee FOREIGN KEY (AssignedUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT FK_FollowUpAssignment_AssignedBy FOREIGN KEY (AssignedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT FK_FollowUpAssignment_LastChangedBy FOREIGN KEY (LastChangedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT CK_FollowUpAssignment_OneTarget CHECK ((PurchaseOrderId IS NOT NULL AND DiscrepancyId IS NULL) OR (PurchaseOrderId IS NULL AND DiscrepancyId IS NOT NULL))
);
GO
CREATE INDEX IX_FollowUpAssignment_Status_Due ON dbo.FollowUpAssignment(StatusCode, DueDate);
GO
CREATE TABLE dbo.FollowUpAssignmentHistory
(
    FollowUpAssignmentHistoryId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_FollowUpAssignmentHistory PRIMARY KEY,
    FollowUpAssignmentId bigint NOT NULL,
    ActionCode varchar(20) NOT NULL,
    PreviousDepartmentOrRole nvarchar(100) NULL,
    NewDepartmentOrRole nvarchar(100) NOT NULL,
    PreviousAssignedUserId int NULL,
    NewAssignedUserId int NULL,
    PreviousAssignedPersonSnapshot nvarchar(200) NULL,
    NewAssignedPersonSnapshot nvarchar(200) NULL,
    PreviousStatusCode varchar(30) NULL,
    NewStatusCode varchar(30) NOT NULL,
    PreviousNextAction nvarchar(1000) NULL,
    NewNextAction nvarchar(1000) NULL,
    PreviousDueDate date NULL,
    NewDueDate date NULL,
    PreviousResolvedAtUtc datetime2(0) NULL,
    NewResolvedAtUtc datetime2(0) NULL,
    PreviousResolution nvarchar(1000) NULL,
    NewResolution nvarchar(1000) NULL,
    OccurredAtUtc datetime2(0) NOT NULL CONSTRAINT DF_FollowUpAssignmentHistory_Time DEFAULT (SYSUTCDATETIME()),
    ActorUserId int NOT NULL,
    Reason nvarchar(1000) NULL,
    CONSTRAINT FK_FollowUpAssignmentHistory_Assignment FOREIGN KEY (FollowUpAssignmentId) REFERENCES dbo.FollowUpAssignment(FollowUpAssignmentId),
    CONSTRAINT FK_FollowUpAssignmentHistory_PreviousAssignee FOREIGN KEY (PreviousAssignedUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT FK_FollowUpAssignmentHistory_NewAssignee FOREIGN KEY (NewAssignedUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT FK_FollowUpAssignmentHistory_Actor FOREIGN KEY (ActorUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT CK_FollowUpAssignmentHistory_Action CHECK (ActionCode IN ('Created', 'Changed'))
);
GO
CREATE INDEX IX_FollowUpAssignmentHistory_Assignment_Time ON dbo.FollowUpAssignmentHistory(FollowUpAssignmentId, OccurredAtUtc);
GO
CREATE TABLE dbo.OutstandingQuantityResolution
(
    OutstandingQuantityResolutionId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_OutstandingQuantityResolution PRIMARY KEY,
    PurchaseOrderId int NOT NULL,
    PurchaseOrderVersionId int NOT NULL,
    PurchaseOrderLineId int NOT NULL,
    PurchaseOrderLineVersionId int NOT NULL,
    Quantity decimal(18,4) NOT NULL,
    Reason nvarchar(1000) NOT NULL,
    AuthorizationDecisionId int NOT NULL,
    ResolvedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_OutstandingQuantityResolution_Time DEFAULT (SYSUTCDATETIME()),
    ResolvedByUserId int NOT NULL,
    EvidenceReference nvarchar(500) NULL,
    Notes nvarchar(1000) NULL,
    CONSTRAINT FK_OutstandingQuantityResolution_Line FOREIGN KEY (PurchaseOrderLineVersionId, PurchaseOrderVersionId, PurchaseOrderId, PurchaseOrderLineId) REFERENCES dbo.PurchaseOrderLineVersion(PurchaseOrderLineVersionId, PurchaseOrderVersionId, PurchaseOrderId, PurchaseOrderLineId),
    CONSTRAINT FK_OutstandingQuantityResolution_Authorization FOREIGN KEY (AuthorizationDecisionId, PurchaseOrderId, PurchaseOrderVersionId) REFERENCES dbo.ApprovalDecision(ApprovalDecisionId, PurchaseOrderId, PurchaseOrderVersionId),
    CONSTRAINT FK_OutstandingQuantityResolution_User FOREIGN KEY (ResolvedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT CK_OutstandingQuantityResolution_Quantity CHECK (Quantity > 0)
);
GO
CREATE INDEX IX_OutstandingQuantityResolution_Line_Time ON dbo.OutstandingQuantityResolution(PurchaseOrderLineVersionId, ResolvedAtUtc);
GO
CREATE TABLE dbo.PurchaseOrderLineEvent
(
    PurchaseOrderLineEventId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_PurchaseOrderLineEvent PRIMARY KEY,
    PurchaseOrderId int NOT NULL,
    PurchaseOrderVersionId int NOT NULL,
    PurchaseOrderLineId int NOT NULL,
    PurchaseOrderLineVersionId int NOT NULL,
    EventType varchar(30) NOT NULL,
    Quantity decimal(18,4) NOT NULL,
    OccurredAtUtc datetime2(0) NOT NULL,
    RecordedByUserId int NOT NULL,
    RelatedFulfillmentEventLineId bigint NULL,
    RelatedDiscrepancyId int NULL,
    RelatedPurchaseOrderLineEventId bigint NULL,
    AuthorizationDecisionId int NULL,
    Reason nvarchar(1000) NOT NULL,
    EvidenceReference nvarchar(500) NULL,
    Notes nvarchar(1000) NULL,
    CONSTRAINT FK_PurchaseOrderLineEvent_Line FOREIGN KEY (PurchaseOrderLineVersionId, PurchaseOrderVersionId, PurchaseOrderId, PurchaseOrderLineId) REFERENCES dbo.PurchaseOrderLineVersion(PurchaseOrderLineVersionId, PurchaseOrderVersionId, PurchaseOrderId, PurchaseOrderLineId),
    CONSTRAINT FK_PurchaseOrderLineEvent_Fulfillment FOREIGN KEY (RelatedFulfillmentEventLineId, PurchaseOrderId, PurchaseOrderLineId) REFERENCES dbo.FulfillmentEventLine(FulfillmentEventLineId, PurchaseOrderId, PurchaseOrderLineId),
    CONSTRAINT FK_PurchaseOrderLineEvent_Discrepancy FOREIGN KEY (RelatedDiscrepancyId, PurchaseOrderId, PurchaseOrderLineId) REFERENCES dbo.Discrepancy(DiscrepancyId, PurchaseOrderId, PurchaseOrderLineId),
    CONSTRAINT FK_PurchaseOrderLineEvent_RelatedEvent FOREIGN KEY (RelatedPurchaseOrderLineEventId, PurchaseOrderId, PurchaseOrderLineId) REFERENCES dbo.PurchaseOrderLineEvent(PurchaseOrderLineEventId, PurchaseOrderId, PurchaseOrderLineId),
    CONSTRAINT FK_PurchaseOrderLineEvent_Authorization FOREIGN KEY (AuthorizationDecisionId, PurchaseOrderId, PurchaseOrderVersionId) REFERENCES dbo.ApprovalDecision(ApprovalDecisionId, PurchaseOrderId, PurchaseOrderVersionId),
    CONSTRAINT FK_PurchaseOrderLineEvent_User FOREIGN KEY (RecordedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT UQ_PurchaseOrderLineEvent_Id_PO_Line UNIQUE (PurchaseOrderLineEventId, PurchaseOrderId, PurchaseOrderLineId),
    CONSTRAINT UQ_PurchaseOrderLineEvent_Exact UNIQUE (PurchaseOrderLineEventId, PurchaseOrderId, PurchaseOrderVersionId, PurchaseOrderLineId, PurchaseOrderLineVersionId),
    CONSTRAINT CK_PurchaseOrderLineEvent_Type CHECK (EventType IN ('Return', 'Replacement', 'Credit', 'ExcessDelivery', 'PartialCancellation')),
    CONSTRAINT CK_PurchaseOrderLineEvent_Quantity CHECK (Quantity > 0),
    CONSTRAINT CK_PurchaseOrderLineEvent_Links CHECK
        ((EventType <> 'Return' OR RelatedFulfillmentEventLineId IS NOT NULL) AND
         (EventType <> 'ExcessDelivery' OR RelatedFulfillmentEventLineId IS NOT NULL) AND
         (EventType <> 'Replacement' OR RelatedPurchaseOrderLineEventId IS NOT NULL OR RelatedDiscrepancyId IS NOT NULL) AND
         (EventType <> 'PartialCancellation' OR AuthorizationDecisionId IS NOT NULL))
);
GO
ALTER TABLE dbo.OutstandingQuantityResolution ADD PurchaseOrderLineEventId bigint NULL;
GO
ALTER TABLE dbo.OutstandingQuantityResolution ADD CONSTRAINT FK_OutstandingQuantityResolution_LineEvent
    FOREIGN KEY (PurchaseOrderLineEventId, PurchaseOrderId, PurchaseOrderVersionId, PurchaseOrderLineId, PurchaseOrderLineVersionId)
    REFERENCES dbo.PurchaseOrderLineEvent(PurchaseOrderLineEventId, PurchaseOrderId, PurchaseOrderVersionId, PurchaseOrderLineId, PurchaseOrderLineVersionId);
GO
CREATE INDEX IX_PurchaseOrderLineEvent_PO_Line_Time ON dbo.PurchaseOrderLineEvent(PurchaseOrderId, PurchaseOrderLineId, OccurredAtUtc);
GO
CREATE TABLE dbo.PurchaseOrderStatusHistory
(
    PurchaseOrderStatusHistoryId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_PurchaseOrderStatusHistory PRIMARY KEY,
    PurchaseOrderId int NOT NULL,
    PreviousStatusCode varchar(40) NULL,
    NewStatusCode varchar(40) NOT NULL,
    ChangedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_PurchaseOrderStatusHistory_Time DEFAULT (SYSUTCDATETIME()),
    ChangedByUserId int NOT NULL,
    Reason nvarchar(1000) NULL,
    AuthorizationDecisionId int NULL,
    CONSTRAINT FK_PurchaseOrderStatusHistory_PO FOREIGN KEY (PurchaseOrderId) REFERENCES dbo.PurchaseOrder(PurchaseOrderId),
    CONSTRAINT FK_PurchaseOrderStatusHistory_Previous FOREIGN KEY (PreviousStatusCode) REFERENCES dbo.PurchaseOrderStatusCode(StatusCode),
    CONSTRAINT FK_PurchaseOrderStatusHistory_New FOREIGN KEY (NewStatusCode) REFERENCES dbo.PurchaseOrderStatusCode(StatusCode),
    CONSTRAINT FK_PurchaseOrderStatusHistory_User FOREIGN KEY (ChangedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT FK_PurchaseOrderStatusHistory_Authorization FOREIGN KEY (AuthorizationDecisionId, PurchaseOrderId) REFERENCES dbo.ApprovalDecision(ApprovalDecisionId, PurchaseOrderId)
);
GO
CREATE INDEX IX_PurchaseOrderStatusHistory_PO_Time ON dbo.PurchaseOrderStatusHistory(PurchaseOrderId, ChangedAtUtc);
GO
CREATE TABLE dbo.InventoryLot
(
    InventoryLotId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_InventoryLot PRIMARY KEY,
    ItemId int NOT NULL,
    SourceFulfillmentEventLineId bigint NOT NULL,
    UnitOfMeasure nvarchar(30) NOT NULL,
    TrackingMethodCode varchar(20) NOT NULL,
    ReceivedQuantity decimal(18,4) NOT NULL,
    SourceEventTypeCode varchar(20) NOT NULL CONSTRAINT DF_InventoryLot_SourceEventType DEFAULT ('PhysicalReceipt'),
    CreatedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_InventoryLot_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
    CreatedByUserId int NOT NULL,
    Reference nvarchar(200) NULL,
    CONSTRAINT FK_InventoryLot_Item FOREIGN KEY (ItemId) REFERENCES dbo.ItemCatalog(ItemId),
    CONSTRAINT FK_InventoryLot_Item_UOM FOREIGN KEY (ItemId, UnitOfMeasure) REFERENCES dbo.ItemCatalog(ItemId, UnitOfMeasure),
    CONSTRAINT FK_InventoryLot_Item_Tracking FOREIGN KEY (ItemId, TrackingMethodCode) REFERENCES dbo.ItemCatalog(ItemId, TrackingMethod),
    CONSTRAINT FK_InventoryLot_SourceLine FOREIGN KEY (SourceFulfillmentEventLineId) REFERENCES dbo.FulfillmentEventLine(FulfillmentEventLineId),
    CONSTRAINT FK_InventoryLot_Source_PhysicalItemUOM FOREIGN KEY (SourceFulfillmentEventLineId, ItemId, UnitOfMeasure, SourceEventTypeCode) REFERENCES dbo.FulfillmentEventLine(FulfillmentEventLineId, ItemId, UnitOfMeasure, EventType),
    CONSTRAINT FK_InventoryLot_User FOREIGN KEY (CreatedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT UQ_InventoryLot_Id_Item UNIQUE (InventoryLotId, ItemId),
    CONSTRAINT UQ_InventoryLot_Id_Tracking UNIQUE (InventoryLotId, TrackingMethodCode),
    CONSTRAINT UQ_InventoryLot_Id_Item_Tracking UNIQUE (InventoryLotId, ItemId, TrackingMethodCode),
    CONSTRAINT CK_InventoryLot_Quantity CHECK (ReceivedQuantity > 0),
    CONSTRAINT CK_InventoryLot_PhysicalReceipt CHECK (SourceEventTypeCode = 'PhysicalReceipt')
);
GO
CREATE TABLE dbo.InventoryUnit
(
    InventoryUnitId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_InventoryUnit PRIMARY KEY,
    InventoryLotId bigint NOT NULL,
    ItemId int NOT NULL,
    TrackingMethodCode varchar(20) NOT NULL CONSTRAINT DF_InventoryUnit_TrackingMethod DEFAULT ('Individual'),
    SerialNumber nvarchar(150) NULL,
    SerialNumberExceptionId bigint NULL,
    ReceivedAtUtc datetime2(0) NOT NULL,
    CreatedByUserId int NOT NULL,
    RetiredAtUtc datetime2(0) NULL,
    Notes nvarchar(500) NULL,
    CONSTRAINT FK_InventoryUnit_Lot_Item FOREIGN KEY (InventoryLotId, ItemId) REFERENCES dbo.InventoryLot(InventoryLotId, ItemId),
    CONSTRAINT FK_InventoryUnit_Lot_Tracking FOREIGN KEY (InventoryLotId, ItemId, TrackingMethodCode) REFERENCES dbo.InventoryLot(InventoryLotId, ItemId, TrackingMethodCode),
    CONSTRAINT FK_InventoryUnit_SerialException FOREIGN KEY (SerialNumberExceptionId, ItemId, SerialNumber) REFERENCES dbo.SerialNumberException(SerialNumberExceptionId, ItemId, SerialNumber),
    CONSTRAINT FK_InventoryUnit_CreatedBy FOREIGN KEY (CreatedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT UQ_InventoryUnit_Id_Item UNIQUE (InventoryUnitId, ItemId),
    CONSTRAINT UQ_InventoryUnit_Id_Tracking UNIQUE (InventoryUnitId, TrackingMethodCode),
    CONSTRAINT CK_InventoryUnit_TrackingMethod CHECK (TrackingMethodCode = 'Individual'),
    CONSTRAINT CK_InventoryUnit_Retirement CHECK (RetiredAtUtc IS NULL OR RetiredAtUtc >= ReceivedAtUtc),
    CONSTRAINT CK_InventoryUnit_ExceptionSerial CHECK (SerialNumberExceptionId IS NULL OR SerialNumber IS NOT NULL)
);
GO
CREATE UNIQUE INDEX UX_InventoryUnit_Item_Serial_NoException ON dbo.InventoryUnit(ItemId, SerialNumber)
    WHERE SerialNumber IS NOT NULL AND SerialNumberExceptionId IS NULL;
GO
CREATE TABLE dbo.OwnershipAccount
(
    OwnershipAccountId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_OwnershipAccount PRIMARY KEY,
    OwnerType varchar(30) NOT NULL,
    Name nvarchar(200) NOT NULL,
    ExternalReference nvarchar(100) NULL,
    IsActive bit NOT NULL CONSTRAINT DF_OwnershipAccount_IsActive DEFAULT (1),
    CONSTRAINT CK_OwnershipAccount_Type CHECK (OwnerType IN ('NIC', 'Customer', 'Other'))
);
GO
CREATE TABLE dbo.InventoryOwnership
(
    InventoryOwnershipId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_InventoryOwnership PRIMARY KEY,
    InventoryLotId bigint NULL,
    InventoryUnitId bigint NULL,
    TrackingMethodCode varchar(20) NOT NULL,
    OwnershipAccountId int NOT NULL,
    Quantity decimal(18,4) NULL,
    EffectiveFromUtc datetime2(0) NOT NULL,
    EffectiveToUtc datetime2(0) NULL,
    RecordedByUserId int NOT NULL,
    Reason nvarchar(1000) NULL,
    EvidenceReference nvarchar(500) NULL,
    CONSTRAINT FK_InventoryOwnership_Lot FOREIGN KEY (InventoryLotId, TrackingMethodCode) REFERENCES dbo.InventoryLot(InventoryLotId, TrackingMethodCode),
    CONSTRAINT FK_InventoryOwnership_Unit FOREIGN KEY (InventoryUnitId, TrackingMethodCode) REFERENCES dbo.InventoryUnit(InventoryUnitId, TrackingMethodCode),
    CONSTRAINT FK_InventoryOwnership_Account FOREIGN KEY (OwnershipAccountId) REFERENCES dbo.OwnershipAccount(OwnershipAccountId),
    CONSTRAINT FK_InventoryOwnership_User FOREIGN KEY (RecordedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT CK_InventoryOwnership_TargetAndQuantity CHECK
        ((InventoryLotId IS NOT NULL AND InventoryUnitId IS NULL AND TrackingMethodCode = 'Quantity' AND Quantity IS NOT NULL AND Quantity > 0) OR
         (InventoryLotId IS NULL AND InventoryUnitId IS NOT NULL AND TrackingMethodCode = 'Individual' AND Quantity IS NULL)),
    CONSTRAINT CK_InventoryOwnership_DateOrder CHECK (EffectiveToUtc IS NULL OR EffectiveToUtc > EffectiveFromUtc)
);
GO
CREATE UNIQUE INDEX UX_InventoryOwnership_Unit_Current ON dbo.InventoryOwnership(InventoryUnitId) WHERE InventoryUnitId IS NOT NULL AND EffectiveToUtc IS NULL;
CREATE UNIQUE INDEX UX_InventoryOwnership_Lot_Owner_Current ON dbo.InventoryOwnership(InventoryLotId, OwnershipAccountId) WHERE InventoryLotId IS NOT NULL AND EffectiveToUtc IS NULL;
CREATE INDEX IX_InventoryOwnership_Owner_End ON dbo.InventoryOwnership(OwnershipAccountId, EffectiveToUtc);
GO
CREATE TABLE dbo.InventoryTransaction
(
    InventoryTransactionId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_InventoryTransaction PRIMARY KEY,
    TransactionType varchar(30) NOT NULL,
    OccurredAtUtc datetime2(0) NOT NULL,
    RecordedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_InventoryTransaction_RecordedAtUtc DEFAULT (SYSUTCDATETIME()),
    RecordedByUserId int NOT NULL,
    ReferenceType varchar(40) NULL,
    ReferenceId bigint NULL,
    Notes nvarchar(1000) NULL,
    CONSTRAINT FK_InventoryTransaction_User FOREIGN KEY (RecordedByUserId) REFERENCES dbo.AppUser(UserId)
);
GO
CREATE TABLE dbo.InventoryTransactionLine
(
    InventoryTransactionLineId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_InventoryTransactionLine PRIMARY KEY,
    InventoryTransactionId bigint NOT NULL,
    ItemId int NOT NULL,
    InventoryLotId bigint NULL,
    InventoryUnitId bigint NULL,
    TrackingMethodCode varchar(20) NOT NULL,
    OwnershipAccountId int NOT NULL,
    FromLocationId int NULL,
    ToLocationId int NULL,
    Quantity decimal(18,4) NOT NULL,
    UnitOfMeasure nvarchar(30) NOT NULL,
    CONSTRAINT FK_InventoryTransactionLine_Transaction FOREIGN KEY (InventoryTransactionId) REFERENCES dbo.InventoryTransaction(InventoryTransactionId),
    CONSTRAINT FK_InventoryTransactionLine_Lot_Item FOREIGN KEY (InventoryLotId, ItemId) REFERENCES dbo.InventoryLot(InventoryLotId, ItemId),
    CONSTRAINT FK_InventoryTransactionLine_Lot_Tracking FOREIGN KEY (InventoryLotId, TrackingMethodCode) REFERENCES dbo.InventoryLot(InventoryLotId, TrackingMethodCode),
    CONSTRAINT FK_InventoryTransactionLine_Item_UOM FOREIGN KEY (ItemId, UnitOfMeasure) REFERENCES dbo.ItemCatalog(ItemId, UnitOfMeasure),
    CONSTRAINT FK_InventoryTransactionLine_Unit_Item FOREIGN KEY (InventoryUnitId, ItemId) REFERENCES dbo.InventoryUnit(InventoryUnitId, ItemId),
    CONSTRAINT FK_InventoryTransactionLine_Unit_Tracking FOREIGN KEY (InventoryUnitId, TrackingMethodCode) REFERENCES dbo.InventoryUnit(InventoryUnitId, TrackingMethodCode),
    CONSTRAINT FK_InventoryTransactionLine_Owner FOREIGN KEY (OwnershipAccountId) REFERENCES dbo.OwnershipAccount(OwnershipAccountId),
    CONSTRAINT FK_InventoryTransactionLine_From FOREIGN KEY (FromLocationId) REFERENCES dbo.InventoryLocation(InventoryLocationId),
    CONSTRAINT FK_InventoryTransactionLine_To FOREIGN KEY (ToLocationId) REFERENCES dbo.InventoryLocation(InventoryLocationId),
    CONSTRAINT CK_InventoryTransactionLine_OneTarget CHECK ((InventoryLotId IS NOT NULL AND InventoryUnitId IS NULL AND TrackingMethodCode = 'Quantity') OR (InventoryLotId IS NULL AND InventoryUnitId IS NOT NULL AND TrackingMethodCode = 'Individual')),
    CONSTRAINT CK_InventoryTransactionLine_Quantity CHECK (Quantity > 0 AND (InventoryUnitId IS NULL OR Quantity = 1)),
    CONSTRAINT CK_InventoryTransactionLine_Locations CHECK
        ((FromLocationId IS NOT NULL OR ToLocationId IS NOT NULL) AND (FromLocationId IS NULL OR ToLocationId IS NULL OR FromLocationId <> ToLocationId))
);
GO
CREATE INDEX IX_InventoryTransactionLine_Lot_Locations ON dbo.InventoryTransactionLine(InventoryLotId, FromLocationId, ToLocationId);
CREATE INDEX IX_InventoryTransactionLine_Unit ON dbo.InventoryTransactionLine(InventoryUnitId);
GO
CREATE TABLE dbo.InventoryBalanceCache
(
    InventoryBalanceCacheId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_InventoryBalanceCache PRIMARY KEY,
    ItemId int NOT NULL,
    InventoryLotId bigint NULL,
    InventoryUnitId bigint NULL,
    TrackingMethodCode varchar(20) NOT NULL,
    InventoryLocationId int NOT NULL,
    OwnershipAccountId int NOT NULL,
    QuantityOnHand decimal(18,4) NOT NULL,
    UnitOfMeasure nvarchar(30) NOT NULL,
    UpdatedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_InventoryBalanceCache_UpdatedAtUtc DEFAULT (SYSUTCDATETIME()),
    UpdatedByUserId int NOT NULL,
    RowVersion rowversion NOT NULL,
    CONSTRAINT FK_InventoryBalanceCache_Item FOREIGN KEY (ItemId) REFERENCES dbo.ItemCatalog(ItemId),
    CONSTRAINT FK_InventoryBalanceCache_Item_UOM FOREIGN KEY (ItemId, UnitOfMeasure) REFERENCES dbo.ItemCatalog(ItemId, UnitOfMeasure),
    CONSTRAINT FK_InventoryBalanceCache_Lot_Item FOREIGN KEY (InventoryLotId, ItemId) REFERENCES dbo.InventoryLot(InventoryLotId, ItemId),
    CONSTRAINT FK_InventoryBalanceCache_Lot_Tracking FOREIGN KEY (InventoryLotId, TrackingMethodCode) REFERENCES dbo.InventoryLot(InventoryLotId, TrackingMethodCode),
    CONSTRAINT FK_InventoryBalanceCache_Unit_Item FOREIGN KEY (InventoryUnitId, ItemId) REFERENCES dbo.InventoryUnit(InventoryUnitId, ItemId),
    CONSTRAINT FK_InventoryBalanceCache_Unit_Tracking FOREIGN KEY (InventoryUnitId, TrackingMethodCode) REFERENCES dbo.InventoryUnit(InventoryUnitId, TrackingMethodCode),
    CONSTRAINT FK_InventoryBalanceCache_Location FOREIGN KEY (InventoryLocationId) REFERENCES dbo.InventoryLocation(InventoryLocationId),
    CONSTRAINT FK_InventoryBalanceCache_Owner FOREIGN KEY (OwnershipAccountId) REFERENCES dbo.OwnershipAccount(OwnershipAccountId),
    CONSTRAINT FK_InventoryBalanceCache_User FOREIGN KEY (UpdatedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT CK_InventoryBalanceCache_OneTarget CHECK ((InventoryLotId IS NOT NULL AND InventoryUnitId IS NULL AND TrackingMethodCode = 'Quantity') OR (InventoryLotId IS NULL AND InventoryUnitId IS NOT NULL AND TrackingMethodCode = 'Individual')),
    CONSTRAINT CK_InventoryBalanceCache_Quantity CHECK (QuantityOnHand >= 0 AND (InventoryUnitId IS NULL OR QuantityOnHand IN (0, 1)))
);
GO
CREATE UNIQUE INDEX UX_InventoryBalanceCache_Lot_Dimension ON dbo.InventoryBalanceCache(InventoryLotId, InventoryLocationId, OwnershipAccountId) WHERE InventoryLotId IS NOT NULL;
CREATE UNIQUE INDEX UX_InventoryBalanceCache_Unit_Current ON dbo.InventoryBalanceCache(InventoryUnitId) WHERE InventoryUnitId IS NOT NULL AND QuantityOnHand > 0;
GO
CREATE TABLE dbo.BusinessRequirement
(
    BusinessRequirementId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_BusinessRequirement PRIMARY KEY,
    RequirementType varchar(40) NOT NULL,
    Reference nvarchar(200) NULL,
    Description nvarchar(1000) NOT NULL,
    RequestedBy nvarchar(200) NULL,
    CreatedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_BusinessRequirement_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
    CreatedByUserId int NOT NULL,
    StatusCode varchar(30) NOT NULL,
    CONSTRAINT FK_BusinessRequirement_User FOREIGN KEY (CreatedByUserId) REFERENCES dbo.AppUser(UserId)
);
GO
CREATE TABLE dbo.InventoryAllocation
(
    InventoryAllocationId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_InventoryAllocation PRIMARY KEY,
    BusinessRequirementId int NOT NULL,
    InventoryLotId bigint NULL,
    InventoryUnitId bigint NULL,
    TrackingMethodCode varchar(20) NOT NULL,
    Quantity decimal(18,4) NOT NULL,
    AllocatedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_InventoryAllocation_AllocatedAtUtc DEFAULT (SYSUTCDATETIME()),
    AllocatedByUserId int NOT NULL,
    LastChangedByUserId int NOT NULL,
    LastChangeActionCode varchar(30) NOT NULL CONSTRAINT DF_InventoryAllocation_LastAction DEFAULT ('Created'),
    LastChangeReason nvarchar(1000) NULL,
    LastChangeAuthorizationReference nvarchar(500) NULL,
    StatusCode varchar(30) NOT NULL,
    ReleasedAtUtc datetime2(0) NULL,
    ExpiresAtUtc datetime2(0) NULL,
    Notes nvarchar(500) NULL,
    RowVersion rowversion NOT NULL,
    CONSTRAINT FK_InventoryAllocation_Requirement FOREIGN KEY (BusinessRequirementId) REFERENCES dbo.BusinessRequirement(BusinessRequirementId),
    CONSTRAINT FK_InventoryAllocation_Lot FOREIGN KEY (InventoryLotId, TrackingMethodCode) REFERENCES dbo.InventoryLot(InventoryLotId, TrackingMethodCode),
    CONSTRAINT FK_InventoryAllocation_Unit FOREIGN KEY (InventoryUnitId, TrackingMethodCode) REFERENCES dbo.InventoryUnit(InventoryUnitId, TrackingMethodCode),
    CONSTRAINT FK_InventoryAllocation_User FOREIGN KEY (AllocatedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT FK_InventoryAllocation_LastChangedBy FOREIGN KEY (LastChangedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT CK_InventoryAllocation_Action CHECK (LastChangeActionCode IN ('Created', 'PartialRelease', 'Released', 'Extended', 'Exception', 'Corrected')),
    CONSTRAINT CK_InventoryAllocation_OneTarget CHECK ((InventoryLotId IS NOT NULL AND InventoryUnitId IS NULL AND TrackingMethodCode = 'Quantity') OR (InventoryLotId IS NULL AND InventoryUnitId IS NOT NULL AND TrackingMethodCode = 'Individual')),
    CONSTRAINT CK_InventoryAllocation_Quantity CHECK (Quantity > 0 AND (InventoryUnitId IS NULL OR Quantity = 1))
);
GO
CREATE INDEX IX_InventoryAllocation_Status_Lot ON dbo.InventoryAllocation(StatusCode, InventoryLotId);
CREATE INDEX IX_InventoryAllocation_Status_Unit ON dbo.InventoryAllocation(StatusCode, InventoryUnitId);
GO
CREATE TABLE dbo.InventoryAllocationHistory
(
    InventoryAllocationHistoryId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_InventoryAllocationHistory PRIMARY KEY,
    InventoryAllocationId bigint NOT NULL,
    ActionCode varchar(30) NOT NULL,
    PreviousQuantity decimal(18,4) NULL,
    NewQuantity decimal(18,4) NOT NULL,
    PreviousStatusCode varchar(30) NULL,
    NewStatusCode varchar(30) NOT NULL,
    PreviousReleasedAtUtc datetime2(0) NULL,
    NewReleasedAtUtc datetime2(0) NULL,
    PreviousExpiresAtUtc datetime2(0) NULL,
    NewExpiresAtUtc datetime2(0) NULL,
    OccurredAtUtc datetime2(0) NOT NULL CONSTRAINT DF_InventoryAllocationHistory_Time DEFAULT (SYSUTCDATETIME()),
    ActorUserId int NOT NULL,
    Reason nvarchar(1000) NULL,
    AuthorizationReference nvarchar(500) NULL,
    CONSTRAINT FK_InventoryAllocationHistory_Allocation FOREIGN KEY (InventoryAllocationId) REFERENCES dbo.InventoryAllocation(InventoryAllocationId),
    CONSTRAINT FK_InventoryAllocationHistory_User FOREIGN KEY (ActorUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT CK_InventoryAllocationHistory_Quantities CHECK (NewQuantity >= 0 AND (PreviousQuantity IS NULL OR PreviousQuantity >= 0)),
    CONSTRAINT CK_InventoryAllocationHistory_Action CHECK (ActionCode IN ('Created', 'PartialRelease', 'Released', 'Extended', 'Exception', 'Corrected'))
);
GO
CREATE INDEX IX_InventoryAllocationHistory_Allocation_Time ON dbo.InventoryAllocationHistory(InventoryAllocationId, OccurredAtUtc);
GO
/* EntitlementReference and Notes are non-secret business references only; no activation credential is stored here. */
CREATE TABLE dbo.SoftwareEntitlement
(
    SoftwareEntitlementId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SoftwareEntitlement PRIMARY KEY,
    PurchaseOrderLineId int NOT NULL,
    ItemId int NULL,
    PublisherOrganizationId int NULL,
    PublisherRoleCode varchar(30) NULL,
    EntitlementType varchar(40) NOT NULL,
    EntitlementReference nvarchar(200) NULL,
    ScopeDescription nvarchar(500) NULL,
    Quantity decimal(18,4) NULL,
    ProvisioningStatus varchar(30) NULL,
    Notes nvarchar(1000) NULL,
    CreatedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_SoftwareEntitlement_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
    CreatedByUserId int NOT NULL,
    CONSTRAINT FK_SoftwareEntitlement_Line FOREIGN KEY (PurchaseOrderLineId) REFERENCES dbo.PurchaseOrderLine(PurchaseOrderLineId),
    CONSTRAINT FK_SoftwareEntitlement_Item FOREIGN KEY (ItemId) REFERENCES dbo.ItemCatalog(ItemId),
    CONSTRAINT FK_SoftwareEntitlement_Publisher FOREIGN KEY (PublisherOrganizationId) REFERENCES dbo.Organization(OrganizationId),
    CONSTRAINT FK_SoftwareEntitlement_PublisherRole FOREIGN KEY (PublisherOrganizationId, PublisherRoleCode) REFERENCES dbo.OrganizationRole(OrganizationId, RoleCode),
    CONSTRAINT FK_SoftwareEntitlement_User FOREIGN KEY (CreatedByUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT CK_SoftwareEntitlement_PublisherRole CHECK ((PublisherOrganizationId IS NULL AND PublisherRoleCode IS NULL) OR (PublisherOrganizationId IS NOT NULL AND PublisherRoleCode = 'ManufacturerPublisher')),
    CONSTRAINT CK_SoftwareEntitlement_Quantity CHECK (Quantity IS NULL OR Quantity >= 0)
);
GO
CREATE INDEX IX_SoftwareEntitlement_Line ON dbo.SoftwareEntitlement(PurchaseOrderLineId);
GO
CREATE TABLE dbo.Subscription
(
    SubscriptionId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Subscription PRIMARY KEY,
    SoftwareEntitlementId int NOT NULL,
    StartDate date NULL,
    EndDate date NULL,
    RenewalDate date NULL,
    RenewalPurchaseOrderLineId int NULL,
    StatusCode varchar(30) NOT NULL,
    Notes nvarchar(1000) NULL,
    RowVersion rowversion NOT NULL,
    CONSTRAINT FK_Subscription_Entitlement FOREIGN KEY (SoftwareEntitlementId) REFERENCES dbo.SoftwareEntitlement(SoftwareEntitlementId),
    CONSTRAINT FK_Subscription_RenewalLine FOREIGN KEY (RenewalPurchaseOrderLineId) REFERENCES dbo.PurchaseOrderLine(PurchaseOrderLineId),
    CONSTRAINT CK_Subscription_DateOrder CHECK (StartDate IS NULL OR EndDate IS NULL OR EndDate >= StartDate)
);
GO
CREATE INDEX IX_Subscription_End_Renewal ON dbo.Subscription(EndDate, RenewalDate);
GO
CREATE TABLE dbo.SoftwareEntitlementEvent
(
    SoftwareEntitlementEventId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_SoftwareEntitlementEvent PRIMARY KEY,
    SoftwareEntitlementId int NOT NULL,
    EventType varchar(30) NOT NULL,
    OccurredAtUtc datetime2(0) NOT NULL,
    RecordedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_SoftwareEntitlementEvent_RecordedAtUtc DEFAULT (SYSUTCDATETIME()),
    ActorUserId int NOT NULL,
    SubjectReference nvarchar(200) NULL,
    Notes nvarchar(1000) NULL,
    CONSTRAINT FK_SoftwareEntitlementEvent_Entitlement FOREIGN KEY (SoftwareEntitlementId) REFERENCES dbo.SoftwareEntitlement(SoftwareEntitlementId),
    CONSTRAINT FK_SoftwareEntitlementEvent_User FOREIGN KEY (ActorUserId) REFERENCES dbo.AppUser(UserId)
);
GO
CREATE TABLE dbo.BusinessEvent
(
    BusinessEventId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_BusinessEvent PRIMARY KEY,
    EventType varchar(50) NOT NULL,
    OccurredAtUtc datetime2(0) NOT NULL,
    RecordedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_BusinessEvent_RecordedAtUtc DEFAULT (SYSUTCDATETIME()),
    ActorUserId int NULL,
    EntityType varchar(50) NOT NULL,
    EntityId bigint NOT NULL,
    Summary nvarchar(1000) NOT NULL,
    Details nvarchar(max) NULL,
    CorrectsBusinessEventId bigint NULL,
    CorrectionReason nvarchar(1000) NULL,
    CONSTRAINT FK_BusinessEvent_Actor FOREIGN KEY (ActorUserId) REFERENCES dbo.AppUser(UserId),
    CONSTRAINT FK_BusinessEvent_Corrects FOREIGN KEY (CorrectsBusinessEventId) REFERENCES dbo.BusinessEvent(BusinessEventId),
    CONSTRAINT CK_BusinessEvent_Correction CHECK
        ((CorrectsBusinessEventId IS NULL AND CorrectionReason IS NULL) OR
         (CorrectsBusinessEventId IS NOT NULL AND CorrectionReason IS NOT NULL))
);
GO
CREATE INDEX IX_BusinessEvent_Entity_Time ON dbo.BusinessEvent(EntityType, EntityId, OccurredAtUtc);
GO

/* Helpful FK/query indexes not already covered by PK/unique indexes. */
CREATE INDEX IX_SupplierContact_Organization_Active ON dbo.SupplierContact(SupplierOrganizationId, IsActive);
CREATE INDEX IX_SupplierAddress_Organization_Active ON dbo.SupplierAddress(SupplierOrganizationId, IsActive);
GO

/*
Application and database security configuration is intentionally not included. The role/permission matrix and audit-retention period remain deferred. Restrict UPDATE/DELETE on append-only history/event tables through approved database permissions; record corrections as new events.

Populate PurchaseOrderStatusCode through a separately reviewed reference-data step with these six pairs; this script intentionally contains no INSERT statements:
Draft | Draft | Being prepared and not yet approved
OnOrder | On Order | Approved and placed, fulfillment outstanding
PartiallyReceivedFulfilled | Partially Received/Fulfilled | Some, but not all, obligations fulfilled
OnHold | On Hold | An unresolved issue prevents normal progress
Closed | Closed | Obligations complete or authorized resolution permits closure
Cancelled | Cancelled | Cancelled with required authorization and history

The schema does not encode a full PO transition matrix. Approved baseline direction includes automatic On Order -> PartiallyReceivedFulfilled on first partial fulfillment, authorized user action for judgment-based hold/cancellation/closure with outstanding obligations, release from hold to an appropriate working status, Closed/Cancelled terminal in normal processing, and exceptional reopening with separate authorization and audit. Validate transitions and the required VP Finance approval for every placement in application transactions.
*/

/* Targeted integrity protections and consistency checks from the review. */
GO
CREATE TRIGGER dbo.TR_PurchaseOrderVersion_Immutable
ON dbo.PurchaseOrderVersion
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51001, 'PurchaseOrderVersion snapshots are immutable; create a new version or a separately authorized traceable correction.', 1;
END;
GO
CREATE TRIGGER dbo.TR_PurchaseOrderLineVersion_Immutable
ON dbo.PurchaseOrderLineVersion
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51002, 'PurchaseOrderLineVersion snapshots are immutable; create a new version or a separately authorized traceable correction.', 1;
END;
GO

/*
A physical inventory lot must originate from a physical receipt line and its
item/UOM. Composite foreign keys enforce that exact line and event type. These
triggers enforce the cross-row accepted-quantity limit and serialize concurrent
lot creation against the receipt disposition row. The receipt disposition,
matching history, inventory transaction rows, ownership changes, and balance
cache update still belong in one application transaction.
*/
CREATE TRIGGER dbo.TR_InventoryLot_ValidateAcceptedReceipt
ON dbo.InventoryLot
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS
    (
        SELECT 1
        FROM inserted i
        LEFT JOIN dbo.ReceiptDisposition d WITH (UPDLOCK, HOLDLOCK)
            ON d.FulfillmentEventLineId = i.SourceFulfillmentEventLineId
        WHERE d.ReceiptDispositionId IS NULL
    )
    BEGIN
        ;THROW 51003, 'An inventory lot requires a current receipt disposition for its physical receipt line.', 1;
    END;

    IF EXISTS
    (
        SELECT 1
        FROM inserted i
        JOIN dbo.ReceiptDisposition d WITH (UPDLOCK, HOLDLOCK)
            ON d.FulfillmentEventLineId = i.SourceFulfillmentEventLineId
        JOIN dbo.FulfillmentEventLine fl
            ON fl.FulfillmentEventLineId = i.SourceFulfillmentEventLineId
        WHERE d.AcceptedQuantity <= 0
           OR d.AcceptedQuantity + d.HeldQuantity + d.RejectedQuantity > fl.Quantity
           OR (SELECT SUM(l.ReceivedQuantity)
               FROM dbo.InventoryLot l
               WHERE l.SourceFulfillmentEventLineId = i.SourceFulfillmentEventLineId) > d.AcceptedQuantity
    )
    BEGIN
        ;THROW 51004, 'Lot quantity must be within the accepted quantity of its physical receipt line.', 1;
    END;
END;
GO
CREATE TRIGGER dbo.TR_ReceiptDisposition_ProtectLotQuantity
ON dbo.ReceiptDisposition
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS
    (
        SELECT 1
        FROM deleted d
        LEFT JOIN inserted i ON i.ReceiptDispositionId = d.ReceiptDispositionId
        WHERE i.ReceiptDispositionId IS NULL
    )
    BEGIN
        ;THROW 51012, 'Current receipt dispositions cannot be deleted; retain the current state and its history.', 1;
    END;
    IF EXISTS
    (
        SELECT 1
        FROM inserted d
        JOIN dbo.FulfillmentEventLine fl
            ON fl.FulfillmentEventLineId = d.FulfillmentEventLineId
        WHERE fl.EventType <> 'PhysicalReceipt'
           OR d.AcceptedQuantity + d.HeldQuantity + d.RejectedQuantity > fl.Quantity
           OR (SELECT COALESCE(SUM(l.ReceivedQuantity), 0)
               FROM dbo.InventoryLot l
               WHERE l.SourceFulfillmentEventLineId = d.FulfillmentEventLineId) > d.AcceptedQuantity
    )
    BEGIN
        ;THROW 51005, 'A disposition requires a physical receipt line; quantities cannot exceed the line or fall below inventory already lotted.', 1;
    END;

    /* The matching history row is written by this trigger in the same transaction. */
    INSERT dbo.ReceiptDispositionHistory
    (
        ReceiptDispositionId, FulfillmentEventLineId,
        PreviousAcceptedQuantity, NewAcceptedQuantity,
        PreviousHeldQuantity, NewHeldQuantity,
        PreviousRejectedQuantity, NewRejectedQuantity,
        ChangedAtUtc, ChangedByUserId, Reason, EvidenceReference
    )
    SELECT i.ReceiptDispositionId, i.FulfillmentEventLineId,
           d.AcceptedQuantity, i.AcceptedQuantity,
           d.HeldQuantity, i.HeldQuantity,
           d.RejectedQuantity, i.RejectedQuantity,
           SYSUTCDATETIME(), i.UpdatedByUserId, i.LastChangeReason, i.LastChangeEvidenceReference
    FROM inserted i
    LEFT JOIN deleted d ON d.ReceiptDispositionId = i.ReceiptDispositionId;
END;
GO

/* Initial INSERTs remain allowed. Corrections are additional traceable rows. */
CREATE TRIGGER dbo.TR_InventoryLot_AppendOnly
ON dbo.InventoryLot
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51013, 'Inventory lot provenance is immutable; record corrections with additional traceable inventory events.', 1;
END;
GO
CREATE TRIGGER dbo.TR_ReceiptDispositionHistory_AppendOnly
ON dbo.ReceiptDispositionHistory
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51006, 'Receipt disposition history is append-only.', 1;
END;
GO
CREATE TRIGGER dbo.TR_InventoryTransaction_AppendOnly
ON dbo.InventoryTransaction
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51007, 'Inventory transaction history is append-only; correct it with an additional traceable transaction.', 1;
END;
GO
CREATE TRIGGER dbo.TR_InventoryTransactionLine_AppendOnly
ON dbo.InventoryTransactionLine
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51008, 'Inventory transaction lines are append-only; correct them with additional traceable transaction lines.', 1;
END;
GO
CREATE TRIGGER dbo.TR_InventoryAllocationHistory_AppendOnly
ON dbo.InventoryAllocationHistory
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51009, 'Inventory allocation history is append-only.', 1;
END;
GO
CREATE TRIGGER dbo.TR_PurchaseOrderStatusHistory_AppendOnly
ON dbo.PurchaseOrderStatusHistory
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51010, 'Purchase order status history is append-only.', 1;
END;
GO
CREATE TRIGGER dbo.TR_BusinessEvent_AppendOnly
ON dbo.BusinessEvent
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51011, 'Business events are append-only; record corrections as new linked events.', 1;
END;
GO

/*
InventoryBalanceCache is dimensioned by the catalog tracking method: Quantity
items use lot rows; Individual items use unit rows only. The lot ReceivedQuantity
is receipt provenance/control-total data, not an additional on-hand balance.
The composite keys and CHECK constraints enforce that distinction for balance,
transaction, ownership, and allocation targets. Unit balance rows also have a
unique positive row per unit. SQL cannot reconcile quantity-lot balances across
locations/owners, require every unit to have one current owner, or match every
allocation total to availability; use the serialized transaction protocol above.

AllocationHistory is immutable and is written by the Allocation trigger in the
same DML transaction as each create/update. The application must lock the
allocation plus all affected eligible balance and unreleased-allocation rows,
then update Allocation and related cache/movement records in one transaction.
ExpiresAtUtc is informational: expired-but-unreleased quantity remains reserved;
expiry never automatically changes status or ReleasedAtUtc. No expiry, release,
or exception authorization matrix is defined here.

Ownership rows are effective-dated. The trigger permits only closing a current
row; insert the successor in the same transaction and reconcile quantity totals.
*/

/* Protect authoritative business events. Corrections are new linked events; never rewrite these rows. */
GO
CREATE TRIGGER dbo.TR_ApprovalDecision_AppendOnly
ON dbo.ApprovalDecision
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51020, 'Approval decisions are append-only; record any correction as a new traceable event.', 1;
END;
GO
CREATE TRIGGER dbo.TR_OrderPlacement_AppendOnly
ON dbo.OrderPlacement
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51021, 'Order placement records are append-only; record later confirmations or corrections as new events.', 1;
END;
GO
CREATE TRIGGER dbo.TR_FulfillmentEvent_AppendOnly
ON dbo.FulfillmentEvent
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51022, 'Fulfillment events are append-only; correct them with additional traceable events.', 1;
END;
GO
CREATE TRIGGER dbo.TR_FulfillmentEventLine_AppendOnly
ON dbo.FulfillmentEventLine
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51023, 'Fulfillment event lines are append-only; correct them with additional traceable events.', 1;
END;
GO
CREATE TRIGGER dbo.TR_DiscrepancyResolution_AppendOnly
ON dbo.DiscrepancyResolution
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51024, 'Discrepancy resolutions are append-only; record corrections as additional resolution or business events.', 1;
END;
GO
CREATE TRIGGER dbo.TR_OutstandingQuantityResolution_AppendOnly
ON dbo.OutstandingQuantityResolution
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51025, 'Outstanding-quantity resolutions are append-only; record corrections as additional authorized events.', 1;
END;
GO
CREATE TRIGGER dbo.TR_PurchaseOrderLineEvent_AppendOnly
ON dbo.PurchaseOrderLineEvent
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51026, 'Purchase-order line events are append-only; preserve the original event and record a correction separately.', 1;
END;
GO
CREATE TRIGGER dbo.TR_SerialNumberException_AppendOnly
ON dbo.SerialNumberException
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51027, 'Serial-number exception approvals are append-only.', 1;
END;
GO

/* Ownership is effective-dated: only close a current row, then insert its successor in the same transaction. */
CREATE TRIGGER dbo.TR_InventoryOwnership_PreserveHistory
ON dbo.InventoryOwnership
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS
    (
        SELECT 1
        FROM deleted d
        LEFT JOIN inserted i ON i.InventoryOwnershipId = d.InventoryOwnershipId
        WHERE i.InventoryOwnershipId IS NULL
    )
    BEGIN
        ;THROW 51028, 'Ownership history cannot be deleted; close a current row and insert an effective-dated successor.', 1;
    END;

    IF EXISTS
    (
        SELECT 1
        FROM deleted d
        JOIN inserted i ON i.InventoryOwnershipId = d.InventoryOwnershipId
        WHERE d.EffectiveToUtc IS NOT NULL
           OR i.EffectiveToUtc IS NULL
           OR i.EffectiveToUtc <= d.EffectiveFromUtc
           OR EXISTS
              (SELECT i.InventoryLotId, i.InventoryUnitId, i.OwnershipAccountId, i.Quantity,
                      i.EffectiveFromUtc, i.RecordedByUserId, i.Reason, i.EvidenceReference
               EXCEPT
               SELECT d.InventoryLotId, d.InventoryUnitId, d.OwnershipAccountId, d.Quantity,
                      d.EffectiveFromUtc, d.RecordedByUserId, d.Reason, d.EvidenceReference)
    )
    BEGIN
        ;THROW 51029, 'Only EffectiveToUtc may change on a current ownership row, and only to close it.', 1;
    END;
END;
GO

/* Follow-up current state is mutable; every insert/update is captured atomically as structured history. */
CREATE TRIGGER dbo.TR_FollowUpAssignment_Audit
ON dbo.FollowUpAssignment
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS
    (
        SELECT 1
        FROM deleted d
        LEFT JOIN inserted i ON i.FollowUpAssignmentId = d.FollowUpAssignmentId
        WHERE i.FollowUpAssignmentId IS NULL
    )
    BEGIN
        ;THROW 51030, 'Follow-up assignments cannot be deleted; retain their history.', 1;
    END;

    IF EXISTS
    (
        SELECT 1
        FROM deleted d
        JOIN inserted i ON i.FollowUpAssignmentId = d.FollowUpAssignmentId
        WHERE EXISTS
              (SELECT i.PurchaseOrderId, i.DiscrepancyId, i.AssignedAtUtc, i.AssignedByUserId
               EXCEPT
               SELECT d.PurchaseOrderId, d.DiscrepancyId, d.AssignedAtUtc, d.AssignedByUserId)
    )
    BEGIN
        ;THROW 51031, 'A follow-up assignment cannot be moved to another matter or have its creation record rewritten.', 1;
    END;

    INSERT dbo.FollowUpAssignmentHistory
    (
        FollowUpAssignmentId, ActionCode,
        PreviousDepartmentOrRole, NewDepartmentOrRole,
        PreviousAssignedUserId, NewAssignedUserId,
        PreviousAssignedPersonSnapshot, NewAssignedPersonSnapshot,
        PreviousStatusCode, NewStatusCode,
        PreviousNextAction, NewNextAction,
        PreviousDueDate, NewDueDate,
        PreviousResolvedAtUtc, NewResolvedAtUtc,
        PreviousResolution, NewResolution,
        OccurredAtUtc, ActorUserId, Reason
    )
    SELECT i.FollowUpAssignmentId,
           CASE WHEN d.FollowUpAssignmentId IS NULL THEN 'Created' ELSE 'Changed' END,
           d.DepartmentOrRole, i.DepartmentOrRole,
           d.AssignedUserId, i.AssignedUserId,
           d.AssignedPersonSnapshot, i.AssignedPersonSnapshot,
           d.StatusCode, i.StatusCode,
           d.NextAction, i.NextAction,
           d.DueDate, i.DueDate,
           d.ResolvedAtUtc, i.ResolvedAtUtc,
           d.Resolution, i.Resolution,
           SYSUTCDATETIME(), i.LastChangedByUserId, i.LastChangeReason
    FROM inserted i
    LEFT JOIN deleted d ON d.FollowUpAssignmentId = i.FollowUpAssignmentId;
END;
GO
CREATE TRIGGER dbo.TR_InventoryAllocation_Audit
ON dbo.InventoryAllocation
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS
    (
        SELECT 1
        FROM deleted d
        LEFT JOIN inserted i ON i.InventoryAllocationId = d.InventoryAllocationId
        WHERE i.InventoryAllocationId IS NULL
    )
    BEGIN
        ;THROW 51036, 'Allocations cannot be deleted; release or correct them with a traceable state change.', 1;
    END;

    IF EXISTS
    (
        SELECT 1
        FROM deleted d
        JOIN inserted i ON i.InventoryAllocationId = d.InventoryAllocationId
        WHERE EXISTS
              (SELECT i.BusinessRequirementId, i.InventoryLotId, i.InventoryUnitId,
                      i.TrackingMethodCode, i.AllocatedAtUtc, i.AllocatedByUserId
               EXCEPT
               SELECT d.BusinessRequirementId, d.InventoryLotId, d.InventoryUnitId,
                      d.TrackingMethodCode, d.AllocatedAtUtc, d.AllocatedByUserId)
           OR i.LastChangeActionCode = 'Created'
    )
    BEGIN
        ;THROW 51037, 'Allocation identity is stable; use a non-Created lifecycle action for state changes.', 1;
    END;

    IF EXISTS (SELECT 1 FROM inserted i LEFT JOIN deleted d ON d.InventoryAllocationId = i.InventoryAllocationId
               WHERE (d.InventoryAllocationId IS NULL AND i.LastChangeActionCode <> 'Created'))
    BEGIN
        ;THROW 51038, 'An initial allocation must use the Created history action.', 1;
    END;

    INSERT dbo.InventoryAllocationHistory
    (
        InventoryAllocationId, ActionCode, PreviousQuantity, NewQuantity,
        PreviousStatusCode, NewStatusCode,
        PreviousReleasedAtUtc, NewReleasedAtUtc,
        PreviousExpiresAtUtc, NewExpiresAtUtc,
        OccurredAtUtc, ActorUserId, Reason, AuthorizationReference
    )
    SELECT i.InventoryAllocationId, i.LastChangeActionCode, d.Quantity, i.Quantity,
           d.StatusCode, i.StatusCode,
           d.ReleasedAtUtc, i.ReleasedAtUtc,
           d.ExpiresAtUtc, i.ExpiresAtUtc,
           SYSUTCDATETIME(), i.LastChangedByUserId, i.LastChangeReason, i.LastChangeAuthorizationReference
    FROM inserted i
    LEFT JOIN deleted d ON d.InventoryAllocationId = i.InventoryAllocationId;
END;
GO
CREATE TRIGGER dbo.TR_FollowUpAssignmentHistory_AppendOnly
ON dbo.FollowUpAssignmentHistory
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    ;THROW 51032, 'Follow-up assignment history is append-only.', 1;
END;
GO

/* Unit counts may not exceed receipt quantity; applications must finish reconciliation before commit. */
CREATE TRIGGER dbo.TR_InventoryUnit_ValidateLotCount
ON dbo.InventoryUnit
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS
    (
        SELECT 1
        FROM
        (
            SELECT InventoryLotId FROM inserted
            UNION
            SELECT InventoryLotId FROM deleted
        ) t
        JOIN dbo.InventoryLot l WITH (UPDLOCK, HOLDLOCK) ON l.InventoryLotId = t.InventoryLotId
        WHERE l.TrackingMethodCode = 'Individual'
          AND (SELECT COUNT_BIG(*) FROM dbo.InventoryUnit u WHERE u.InventoryLotId = l.InventoryLotId) > l.ReceivedQuantity
    )
    BEGIN
        ;THROW 51033, 'Individually tracked units cannot exceed accepted receipt quantity for their lot.', 1;
    END;
    IF EXISTS
    (
        SELECT 1
        FROM inserted i
        JOIN dbo.InventoryBalanceCache b WITH (UPDLOCK, HOLDLOCK)
            ON b.InventoryUnitId = i.InventoryUnitId
        WHERE i.RetiredAtUtc IS NOT NULL AND b.QuantityOnHand > 0
    )
    BEGIN
        ;THROW 51039, 'A retired inventory unit cannot retain a positive on-hand balance.', 1;
    END;
END;
GO
CREATE TRIGGER dbo.TR_InventoryUnit_PreserveIdentity
ON dbo.InventoryUnit
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS
    (
        SELECT 1
        FROM deleted d
        LEFT JOIN inserted i ON i.InventoryUnitId = d.InventoryUnitId
        WHERE i.InventoryUnitId IS NULL
    )
    BEGIN
        ;THROW 51034, 'Inventory units cannot be deleted; retain unit identity and history.', 1;
    END;
    IF EXISTS
    (
        SELECT 1
        FROM deleted d
        JOIN inserted i ON i.InventoryUnitId = d.InventoryUnitId
        WHERE EXISTS
              (SELECT i.InventoryLotId, i.ItemId, i.TrackingMethodCode, i.SerialNumber,
                      i.SerialNumberExceptionId, i.ReceivedAtUtc, i.CreatedByUserId
               EXCEPT
               SELECT d.InventoryLotId, d.ItemId, d.TrackingMethodCode, d.SerialNumber,
                      d.SerialNumberExceptionId, d.ReceivedAtUtc, d.CreatedByUserId)
    )
    BEGIN
        ;THROW 51035, 'Inventory unit identity and provenance fields are immutable.', 1;
    END;
END;
GO
CREATE TRIGGER dbo.TR_InventoryBalanceCache_ValidateCapacity
ON dbo.InventoryBalanceCache
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS
    (
        SELECT 1
        FROM
        (
            SELECT InventoryLotId FROM inserted WHERE InventoryLotId IS NOT NULL
            UNION
            SELECT InventoryLotId FROM deleted WHERE InventoryLotId IS NOT NULL
        ) t
        JOIN dbo.InventoryLot l WITH (UPDLOCK, HOLDLOCK) ON l.InventoryLotId = t.InventoryLotId
        CROSS APPLY
        (
            SELECT COALESCE(SUM(b.QuantityOnHand), 0) AS CurrentLotBalance
            FROM dbo.InventoryBalanceCache b WITH (UPDLOCK, HOLDLOCK)
            WHERE b.InventoryLotId = l.InventoryLotId
        ) totals
        WHERE l.TrackingMethodCode = 'Quantity'
          AND totals.CurrentLotBalance > l.ReceivedQuantity
    )
    BEGIN
        ;THROW 51040, 'Quantity-tracked balances across all locations and owners cannot exceed accepted lot quantity.', 1;
    END;

    IF EXISTS
    (
        SELECT 1
        FROM inserted b
        JOIN dbo.InventoryUnit u WITH (UPDLOCK, HOLDLOCK) ON u.InventoryUnitId = b.InventoryUnitId
        WHERE b.QuantityOnHand > 0 AND u.RetiredAtUtc IS NOT NULL
    )
    BEGIN
        ;THROW 51041, 'Retired units cannot have positive on-hand balances.', 1;
    END;
END;
GO

