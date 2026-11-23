# Aperture tools that send as Nico (mcp-bridges.nix, messaging-mcp.nix): write as
# Nico to other people, publish, or delete (Nextcloud). Kept out of Code Mode
# (pkgs/agents/aperture-codemode); Hermes reaches them via `aperture-send`.
[
  "mail_send_email"
  "mail_forward_email"
  "messaging_send_message"
  "nextcloud_nc_webdav_delete_resource"
  "nextcloud_nc_calendar_delete_event"
  "nextcloud_nc_calendar_delete_todo"
  "nextcloud_nc_calendar_bulk_operations"
  "nextcloud_nc_calendar_manage_calendar"
  "nextcloud_nc_calendar_create_meeting"
  "nextcloud_nc_calendar_create_event"
  "nextcloud_nc_calendar_update_event"
  "nextcloud_nc_contacts_delete_contact"
  "nextcloud_nc_contacts_delete_addressbook"
  "nextcloud_nc_share_create"
  "nextcloud_nc_share_create_public_link"
  "nextcloud_nc_share_update"
  "nextcloud_nc_share_delete"
  # Cal.com mails the other attendees.
  "calcom_create_booking"
  "calcom_cancel_booking"
  "calcom_reschedule_booking"
  # Seen by his colleagues.
  "lineartrusk_save_issue"
  "lineartrusk_save_comment"
  "lineartrusk_save_project"
]
