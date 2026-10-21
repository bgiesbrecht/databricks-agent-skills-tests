// StringifyField: a Kafka Connect transform that turns named fields of a record's value into JSON text.
// Zerobus takes a VARIANT field only as a JSON-encoded string ("invalid type: map, expected a string"), and no built-in
// transform renders a struct as JSON, so this one does, with Connect's own JsonConverter (schemas off).
//   transforms.json.type=lfc.connect.StringifyField
//   transforms.json.fields=value            (comma-separated top-level fields of the value)
package lfc.connect;

import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.apache.kafka.common.config.ConfigDef;
import org.apache.kafka.connect.connector.ConnectRecord;
import org.apache.kafka.connect.data.Field;
import org.apache.kafka.connect.data.Schema;
import org.apache.kafka.connect.data.SchemaBuilder;
import org.apache.kafka.connect.data.Struct;
import org.apache.kafka.connect.json.JsonConverter;
import org.apache.kafka.connect.transforms.Transformation;

public class StringifyField<R extends ConnectRecord<R>> implements Transformation<R> {
    private List<String> fields;
    private final JsonConverter json = new JsonConverter();

    @Override public void configure(Map<String, ?> props) {
        fields = List.of(((String) props.get("fields")).split(","));
        Map<String, Object> c = new HashMap<>(); c.put("schemas.enable", "false"); c.put("converter.type", "value");
        json.configure(c);
    }

    @Override public R apply(R record) {
        if (!(record.value() instanceof Struct)) return record;
        Struct in = (Struct) record.value();
        SchemaBuilder b = SchemaBuilder.struct().name(in.schema().name());
        for (Field f : in.schema().fields()) b.field(f.name(), fields.contains(f.name()) ? Schema.OPTIONAL_STRING_SCHEMA : f.schema());
        Schema out = b.build();
        Struct v = new Struct(out);
        for (Field f : in.schema().fields()) {
            Object x = in.get(f);
            if (fields.contains(f.name()) && x != null)
                x = new String(json.fromConnectData(record.topic(), f.schema(), x), StandardCharsets.UTF_8);
            v.put(f.name(), x);
        }
        return record.newRecord(record.topic(), record.kafkaPartition(), record.keySchema(), record.key(), out, v, record.timestamp());
    }

    @Override public ConfigDef config() { return new ConfigDef().define("fields", ConfigDef.Type.STRING, ConfigDef.Importance.HIGH, "fields to render as JSON text"); }
    @Override public void close() { json.close(); }
}
