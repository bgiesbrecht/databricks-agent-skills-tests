-- Read-only access for the connector role (created with the skill's role.sql as lfc_shapes_reader)
GRANT USAGE ON SCHEMA lfc_shapes TO lfc_shapes_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA lfc_shapes TO lfc_shapes_reader;
