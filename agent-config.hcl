vault {
    address = "http://127.0.0.1:8200"
}

auto_auth {
    method {
        type = "approle"
        config = {
            role_id_file_path = "role_id"
            secret_id_file_path = "secret_id"
            remove_secret_id_file_after_reading = false
        }
    }
}

template_config {
    error_on_missing_key = true
    static_secret_render_interval = "5s"
}

template {
    source = "./example.ctmpl"
    destination = "./example.output"
    command = "echo systemctl reload foobar"
}
