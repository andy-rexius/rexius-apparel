-- Drop employee numbers.
--
-- Employee numbers are a payroll identifier that nobody looks up day to day,
-- so the app identifies people by name (plus home department) only.
-- The unique index goes away with the column.

alter table apparel.employees drop column if exists employee_no;
