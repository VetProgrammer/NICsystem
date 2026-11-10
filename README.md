

NICsystem
National Independence Computer — Purchasing and Inventory Tracking System
An AI-Assisted Software Engineering Project
Project Overview
NICsystem is a Purchasing and Inventory Control Tracking System being developed for National Independence Computer (NIC).
The system is designed to record, track, and control purchasing and inventory activities while maintaining data integrity, enforcing approved business rules, and preserving an auditable history of business transactions.
Its objective is to provide a structured, reliable, and auditable system that preserves business history, enforces approved business rules, and supports the day-to-day operational requirements of NIC.
The project is being developed incrementally, with particular emphasis on sound system design, data integrity, maintainability, and verification.
An Experiment in AI-Assisted Software Engineering
NICsystem is also an exploration of how Artificial Intelligence can assist an experienced systems engineer throughout the software development lifecycle.
Rather than asking AI to independently design and build an entire application, the project uses a collaborative development approach in which each participant has a defined responsibility.
Team Member	Responsibility
System Designer / Engineer — Jess	Defines business objectives, establishes requirements, makes architectural decisions, approves designs, and performs final acceptance testing.

Advisor — ChatGPT	Assists with requirements analysis, system design, technical planning, documentation, and implementation guidance.

Coder — OpenAI Codex	Implements approved functionality, develops application code, and performs technical checks.

Reviewer — GitHub Copilot	Independently reviews implementations, verifies requirements, assists with troubleshooting, and manages Git version control.
The fundamental principle is that AI assists the engineering process; it does not replace engineering judgment or accountability.
The human System Designer retains responsibility for approving requirements, design decisions, implementation scope, and final results.
Technology
NICsystem is being developed using:
Component	Technology
Application framework	ASP.NET Core MVC
Programming language	C#
.NET platform	.NET 10
Database	Microsoft SQL Server Express
Data access	Entity Framework Core
Development environment	Visual Studio Code / Visual Studio
Version control	Git and GitHub
AI development assistants	ChatGPT, OpenAI Codex, GitHub Copilot
The application currently operates in a local Windows development environment.
System Capabilities
The system is being developed in stages.
Implemented
Organization Management
•	Maintain supplier and manufacturer/publisher organizations.
•	Assign and manage organization roles.
•	Activate and deactivate organizations.
Item Catalog
•	Create and maintain catalog items.
•	Manage item classifications and tracking methods.
•	Associate items with eligible manufacturers or publishers.
•	Activate and deactivate catalog items.
Inventory Reference Data
•	Maintain inventory locations.
•	Maintain ownership accounts.
•	Enforce applicable reference-data validation and integrity rules.
Purchase Order Management — Initial Stage
•	Display existing purchase orders.
•	Retrieve purchase order information from SQL Server.
•	Establish the foundation for future purchase order workflows.
Planned Development
Additional functionality will include:
•	Purchase order creation and revision history.
•	Approval and placement workflows.
•	Supplier acknowledgment and order follow-up.
•	Physical receiving and digital fulfillment.
•	Inventory transactions and availability.
•	Inventory ownership and allocation.
•	Discrepancy management, returns, and replacements.
•	Business event history and audit reporting.
Planned capabilities are not considered implemented until they have been developed and verified.
Design Principles
NICsystem follows several guiding principles.
1. Requirements Before Implementation
Business requirements and approved design decisions should be documented before corresponding functionality is developed.
2. Incremental Development
The application is built in small, manageable steps. Each step is reviewed and tested before additional functionality is introduced.
3. Preservation of Business History
Significant business events, approvals, purchase order versions, inventory transactions, and corrections must remain traceable.
4. Data Integrity
SQL Server constraints and application-level validation work together to enforce business rules and maintain consistent data.
5. Independent Verification
Implementation and verification are treated as separate responsibilities. AI-generated code is subject to independent review and human acceptance testing.
6. Controlled Scope
New functionality is introduced only when justified by approved requirements. Unnecessary complexity and premature expansion are avoided.
Database Design and Version Control
The original SQL Server schema was implemented on October 28, 2026.
The baseline schema script is preserved in Git:
sql/001_NIC_Inventory_Schema.sql
Baseline Git commit:
2e34e3f43ac36abf26884cd7e11df78d5ebf3581
The original schema script is retained as a historical reference. Future approved database changes will be recorded separately rather than modifying the baseline.
The database design is supported by the project's physical schema documentation and approved design decisions.
Documentation and Requirements Traceability
The project maintains design documentation describing business requirements, database structures, application behavior, and approved decisions.
Requirements traceability is being formalized to connect:
Business Requirement → Design Decision → Implementation → Verification → Acceptance
This provides a basis for independent review and helps ensure that implementation remains consistent with the approved design.
Current Project Status
Development status: Active — Incremental Implementation
Core reference-data management features have been implemented.
Purchase Order Management is in its early development stage. The existing database and read-only purchase order listing provide a foundation for subsequent purchasing workflows.
The next phase focuses on consolidating approved purchase order requirements, reconciling them with the existing design, and establishing verification criteria before further implementation.
The system is not yet production-ready. Development-only access controls are in use, and production authentication and authorization remain future requirements.
A Note on the Development Approach
This project demonstrates an approach to software development in which an experienced systems engineer works with multiple AI assistants, assigning each a specific role.
The value of this approach lies not simply in generating code more quickly, but in combining human experience, structured reasoning, automated implementation, independent review, and disciplined verification.
The objective is to develop a useful information system while learning how AI can become an effective member of a software engineering team.
________________________________________
NICsystem — Designed with human judgment, developed with AI assistance, and verified through disciplined engineering.
