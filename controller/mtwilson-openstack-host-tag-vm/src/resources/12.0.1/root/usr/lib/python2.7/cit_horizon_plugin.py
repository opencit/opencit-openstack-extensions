from django.utils.translation import ugettext_lazy as _
from django.template import defaultfilters as filters
from horizon import tables
from horizon import forms

from openstack_dashboard.dashboards.admin.hypervisors import tables as hypervisors_tables
from openstack_dashboard.dashboards.admin.hypervisors import tabs as hypervisors_tabs

from openstack_dashboard.dashboards.admin.images import tables as images_tables
from openstack_dashboard.dashboards.admin.images import views as images_view

from openstack_dashboard.dashboards.project.images.images import tables as proj_images_tables
from openstack_dashboard.dashboards.project.images.images import forms as proj_images_forms
from openstack_dashboard.dashboards.project.images import views as proj_images_main_view
from openstack_dashboard.dashboards.project.images.images import views as proj_images_view
from openstack_dashboard.dashboards.admin.images import views as admin_images_view

from openstack_dashboard.dashboards.admin.instances import tables as instances_tables
from openstack_dashboard.dashboards.admin.instances import views as instances_view
from openstack_dashboard.dashboards.project.instances import tables as project_instances_tables
from openstack_dashboard.dashboards.project.instances import views as project_instances_view

from openstack_dashboard import api
import glanceclient as glance_client

import horizon_utils
import logging
import json
from django.conf import settings  # noqa

LOG = logging.getLogger(__name__)

# BEGIN: Common Methods

def safe_from_escaping(value):
    return filters.safe(value)

def generate_attestation_status_str(policy, policy_status, asset_tag):
    trust_type = "no_trust"
    return_string = "<span class='fa {}' title='{}'></span>"
    if(policy != 'none'):
        return_string += "<img style='height: 18px; padding-left: 10px;' src='{}' title='{}' />"

    launch_image_name="/static/dashboard/img/policy_unknown.png"
    launch_image_tooltip = 'Launch policy: Unknown'

    tag_image_tooltip = 'Trust: No; Asset Tags: None'

    if policy == 'MeasureOnly':
        if policy_status == 'true':
            launch_image_name='/static/dashboard/img/measure_success.png'
            launch_image_tooltip = 'Launch policy: Measured and launched'
        else:
            launch_image_name='/static/dashboard/img/measure_fail.png'
            launch_image_tooltip = 'Launch policy: Failed VM measure'
    elif policy == 'MeasureAndEnforce':
        if policy_status == 'true':
            launch_image_name='/static/dashboard/img/measure_enforce_success.png'
            launch_image_tooltip = 'Launch policy: Measured and Enforced'
        else:
            launch_image_name='/static/dashboard/img/measure_enforce_fail.png'
            launch_image_tooltip = 'Launch policy: Failed VM measure'

    if(policy == 'none'):
        launch_image_tooltip = ''

    if(asset_tag != '-' and asset_tag is not None):
        tag_dictionary = asset_tag

        if(type(tag_dictionary) is unicode):
            tag_dictionary = (tag_dictionary.encode('utf8'))

        if(type(tag_dictionary) is str):
            tag_dictionary = json.loads(tag_dictionary)

        if('trust' in tag_dictionary and tag_dictionary['trust'] == 'true'):
            trust_type = 'trust_only'
            tags = None
            if 'tags' in tag_dictionary:
                tags = tag_dictionary['tags']
            tag_image_tooltip = 'Trust: Yes; Asset tags: None'
            if(tags == 'None'):
                return return_string.format(trust_type, tag_image_tooltip +  '; ' + launch_image_tooltip, launch_image_name, tag_image_tooltip + '; ' + launch_image_tooltip)

            if(type(tags) is unicode):
                tags = (tags.encode('utf8'))

            if(type(tags) is str):
                tags = json.loads(tags)

            #if ('tags' in tag_dictionary.keys() and tag_dictionary['tags'] != 'None' and len(tags.keys()) != 0):
            if (tags != None and tags != {}):
                tag_image_tooltip = 'Trust: Yes; Asset tags: ' + json.dumps(tags)
                trust_type = 'trust_and_geo'
        
    return return_string.format(trust_type, tag_image_tooltip +  '; ' + launch_image_tooltip, launch_image_name, tag_image_tooltip + '; ' + launch_image_tooltip)
    #return return_string.format(trust_type, tag_image_tooltip, launch_image_name, launch_image_tooltip)

# END: Common Methods

# BEGIN: Changes to add the Geo Tag column in the Instances table view
def get_instance_attestation_status(instance):
    instance_metadata = getattr(instance, "metadata", None)
    LOG.error("******************************************")
    LOG.error(instance_metadata)

    instance_tags = '{}'
    if(instance.tag_properties != '-'):
        instance_tags = instance.tag_properties

    if('measurement_policy' not in instance_metadata):
        return generate_attestation_status_str('na', 'false', instance_tags)
    policy = instance_metadata['measurement_policy']
    policy_status = instance_metadata['measurement_status']

    return generate_attestation_status_str(policy, policy_status, instance_tags)

class GeoTagInstancesTable(project_instances_tables.InstancesTable):

    attestation_status = tables.Column(get_instance_attestation_status,
        verbose_name=_("Attestation Status"),
        filters=(safe_from_escaping,))

    class Meta(instances_tables.AdminInstancesTable.Meta):
        name = "instances"
        columns = ('name', 'image_name', 'attestation_status', 'ip', 'size', 'keypair', 'status', 'az', 'task', 'state', 'created')
        verbose_name = _("Instances")
        status_columns = ["status", "task"]
        row_class = project_instances_tables.UpdateRow
        table_actions = (project_instances_tables.LaunchLink, project_instances_tables.SoftRebootInstance, project_instances_tables.TerminateInstance, project_instances_tables.InstancesFilterAction)
        row_actions = (project_instances_tables.StartInstance, project_instances_tables.ConfirmResize, project_instances_tables.RevertResize,
                       project_instances_tables.CreateSnapshot, project_instances_tables.SimpleAssociateIP, project_instances_tables.AssociateIP,
                       project_instances_tables.SimpleDisassociateIP, project_instances_tables.EditInstance,
                       project_instances_tables.DecryptInstancePassword, project_instances_tables.EditInstanceSecurityGroups,
                       project_instances_tables.ConsoleLink, project_instances_tables.LogLink, project_instances_tables.TogglePause, project_instances_tables.ToggleSuspend,
                       project_instances_tables.ResizeLink, project_instances_tables.SoftRebootInstance, project_instances_tables.RebootInstance,
                       project_instances_tables.StopInstance, project_instances_tables.RebuildInstance, project_instances_tables.TerminateInstance)

class GeoTagAdminInstancesTable(instances_tables.AdminInstancesTable):

    attestation_status = tables.Column(get_instance_attestation_status,
        verbose_name=_("Attestation Status"),
        filters=(safe_from_escaping,))

    class Meta(instances_tables.AdminInstancesTable.Meta):
        name = "instances"
        columns = ('host', 'name', 'image_name', 'attestation_status', 'ip', 'size', 'status', 'task', 'state', 'created')



instances_view.AdminIndexView.table_class = GeoTagAdminInstancesTable
project_instances_view.IndexView.table_class = GeoTagInstancesTable

# END: Changes to add the Geo Tag column in the Instances table view

# BEGIN: Changes to add the Geo Tag column in the hypervisors table view

def get_host_trust_status(hypervisor):
    utils = horizon_utils.SelectionUtils()
    return generate_attestation_status_str('none', 'na', utils.get_hypervisr_trust_status(hypervisor))

class GeoTagHypervisorsTable(hypervisors_tables.AdminHypervisorsTable):

    geo_tag = tables.Column(get_host_trust_status,
        verbose_name=_("Geo/Asset Tag"),
        filters=(safe_from_escaping,))

    class Meta(hypervisors_tables.AdminHypervisorsTable.Meta):
        name = "hypervisors"
        columns = ('hostname', 'geo_tag', 'vcpus', 'vcpus_used', 'memory', 'memory_used', 'local', 'local_used', 'running_vms')

hypervisors_tabs.HypervisorTab.table_classes = (GeoTagHypervisorsTable,)
# END: Changes to add the Geo Tag column in the hypervisors table view

# BEGIN: Changes to add the tag creation in the create image form

def get_tags_json():
    utils = horizon_utils.SelectionUtils()
    return utils.get_selections()

class GeoTagCreateImageForm(proj_images_forms.CreateImageForm):

    trust_type = forms.MultipleChoiceField(
        label=_('Trust Policy'),
        required=False,
        widget=forms.CheckboxSelectMultiple,
        choices=[('trust', _('Trust only')),
                 ('trust_loc', _('Trust and Location'))])

    json_field = forms.CharField(
        label=_("Tags"),
        initial=get_tags_json,
        widget=forms.HiddenInput())


    geoTag = forms.CharField(
        label=_("Tags"),
        widget=forms.HiddenInput())

proj_images_view.CreateView.form_class = GeoTagCreateImageForm
admin_images_view.CreateView.form_class = GeoTagCreateImageForm

# END: Changes to add the tag creation in the create image form


# BEGIN: Changes to add the tag creation in the create image form
def get_image_props(image):
    utils = horizon_utils.SelectionUtils()
    return utils.get_image_selection(image)

class GeoTagUpdateImageForm(proj_images_forms.UpdateImageForm):

    trust_type = forms.MultipleChoiceField(
        label=_('Trust Policy'),
        required=False,
        widget=forms.CheckboxSelectMultiple,
        choices=[('trust', _('Trust only')),
                 ('trust_loc', _('Trust and Location'))])

    json_field = forms.CharField(
        label=_("Tags"),
        initial=get_tags_json,
        widget=forms.HiddenInput())

    properties = forms.CharField(
        label=_("Tags"),
        widget=forms.HiddenInput())

    geoTag = forms.CharField(
        label=_("Tags"),
        widget=forms.HiddenInput())

proj_images_view.UpdateView.form_class = GeoTagUpdateImageForm
admin_images_view.UpdateView.form_class = GeoTagUpdateImageForm

# END: Changes to add the tag creation in the create image form

# BEGIN: Changes to add the Geo Tag column in the Images table view

def get_image_selection(image):
    utils = horizon_utils.SelectionUtils()
    return generate_attestation_status_str('none', 'na', utils.get_image_selection(image))

class GeoTagImagesTable(proj_images_tables.ImagesTable):

    image_policy = tables.Column(get_image_selection,
        verbose_name=_("Image policies"),
        filters=(safe_from_escaping,))

    class Meta(images_tables.AdminImagesTable.Meta):
        name = "images"
        columns = ('name', 'image_type', 'image_policy', 'status', 'public', 'protected', 'disk_format')
        row_class = proj_images_tables.UpdateRow
        status_columns = ["status"]
        verbose_name = _("Images")
        table_actions = (proj_images_tables.OwnerFilter, proj_images_tables.CreateImage, proj_images_tables.DeleteImage,)
        row_actions = (proj_images_tables.LaunchImage, proj_images_tables.CreateVolumeFromImage,
                       proj_images_tables.EditImage, proj_images_tables.DeleteImage,)
        pagination_param = "image_marker"


class GeoTagAdminImagesTable(images_tables.AdminImagesTable):

    image_policy = tables.Column(get_image_selection,
        verbose_name=_("Image policies"),
        filters=(safe_from_escaping,))

    class Meta(images_tables.AdminImagesTable.Meta):
        name = "images"
        columns = ('name', 'image_type', 'image_policy', 'status', 'public', 'protected', 'disk_format')

images_view.IndexView.table_class = GeoTagAdminImagesTable
proj_images_main_view.IndexView.table_class = GeoTagImagesTable

# END: Changes to add the Geo Tag column in the Images table view

