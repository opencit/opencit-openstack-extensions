$( document ).ready(function() {
/*	var col_num = get_geo_policy_column();

	if(col_num > -1) {
		check_and_convert_geo_tag_column(col_num);
	}*/
});


var tags_object = {};
var tags_object_parsed = false;

function parse_and_save_tags() {
	if(tags_object_parsed) return;
	var json = JSON.parse($("#id_json_field")[0].value);

	var kv_objects = json.kv_attributes;

	for(var loop = 0; loop < kv_objects.length; loop++) {
		if(kv_objects[loop].name in tags_object) {
			tags_object[kv_objects[loop].name].push(kv_objects[loop].value);
		} else {
			tags_object[kv_objects[loop].name] = [];
			tags_object[kv_objects[loop].name].push(kv_objects[loop].value);
		}
	}
	tags_object_parsed= true;
}

var tag_elements_set = false;
var num_tag_elements = 0;
var update_tags_set = false;
var is_tag_trust_checked = false;

setInterval( function() {
	if($('#create_image_form').is(':visible')){
		if( $("#id_trust_type_1").is(':checked')) { 
			setTagElements();
			tag_elements_set = true;
			$("#id_trust_type_0").prop('checked', true);
		} else if( $("#id_trust_type_0").is(':checked')) { 
			$('.tag_elements').hide();
			tag_elements_set = false;
			num_tag_elements = 0;
			var assetTags = {};
			assetTags['trust'] = 'true';
			document.getElementById('id_geoTag').value = JSON.stringify(assetTags);
		} else { 
			var assetTags = {};
			assetTags['trust'] = 'false';
			document.getElementById('id_geoTag').value = JSON.stringify(assetTags);
			$('.tag_elements').hide();
			tag_elements_set = false;
			num_tag_elements = 0;
		}
	} else if($('#update_image_form').is(':visible')){
		if(!update_tags_set) {
			populateUpdateTagsView();
			update_tags_set = true;
			is_tag_trust_checked =  $("#id_trust_type_1").is(':checked');
			document.getElementById('id_geoTag').value = document.getElementById('id_properties').value;
		} 	
		if( $("#id_trust_type_1").is(':checked')) { 
//			if(!is_tag_trust_checked) {
				setTagElements();
				is_tag_trust_checked = true;
//			}
			tag_elements_set = true;
			$("#id_trust_type_0").prop('checked', true);
		} else if( $("#id_trust_type_0").is(':checked')) { 
			var assetTags = {};
			assetTags['trust'] = 'true';
			document.getElementById('id_geoTag').value = JSON.stringify(assetTags);
			$('.tag_elements').hide();
			tag_elements_set = false;
			num_tag_elements = 0;
		} else { 
			var assetTags = {};
			assetTags['trust'] = 'false';
			document.getElementById('id_geoTag').value = JSON.stringify(assetTags);
			$('.tag_elements').hide();
			tag_elements_set = false;
			num_tag_elements = 0;
		}

	} else {
		tag_elements_set = false;
		update_tags_set = false;
		num_tag_elements = 0;
		update_tags_set = false;
		is_tag_trust_checked = false;
	}


}, 100);

function populateUpdateTagsView() {
	var setProps = '{}';
	if($('#id_properties')[0].value != "") {
		setProps = $('#id_properties')[0].value;
	}
	assetTagDetails = JSON.parse(setProps);
//	num_tag_elements = 10;
	if(assetTagDetails.hasOwnProperty('mtwilson_trustpolicy_location')) {
		$('#id_trust_type_0')[0].disabled = 'disabled';
	}
	if(assetTagDetails.hasOwnProperty('mtwilson_trustpolicy_location') || ( assetTagDetails.hasOwnProperty('trust') && assetTagDetails['trust'].trim().toLowerCase() == 'true')) {
		if(assetTagDetails.hasOwnProperty('tags') && assetTagDetails['tags'] != 'None') {
			$('#id_trust_type_1')[0].checked = true;
		 }
		$('#id_trust_type_0')[0].checked = true;
	}
	
	if(typeof assetTagDetails['tags'] == 'undefined' || assetTagDetails['tags'] == 'None') { return }

	var tags = JSON.parse(assetTagDetails['tags']);
	num_tag_elements = 0;
	for(key in tags) {
		for(val in tags[key]) {
			setTagElements(true, key, tags[key][val]);
		}
	}
}

function setTagElements(override_flag, key, value) {

//	change_add_button(obj);

	if(override_flag === undefined) {
		override_flag = false;
	}
	parse_and_save_tags();

	if((tag_elements_set && !override_flag) || num_tag_elements > 4) return;
	
	var elements = createTagElements(key, value);

	var form = document.getElementById('create_image_form');
	if(form == null) {
		form = document.getElementById('update_image_form');
	}

	var form_fields = form.getElementsByTagName('fieldset');

	form_fields[0].appendChild(elements);
	$('#tag-key-select-' + num_tag_elements).focus();
	num_tag_elements++;

	tag_elements_set = true;
}

function change_add_button(obj) {
	if(obj === undefined) {
		return;
	}

	obj.setAttribute('href', 'javascript:removeTagElement(this)');
}

function createTagElements(key, value) {
	var div = document.createElement('div');
	div.setAttribute('class', 'tag_elements');

	div.appendChild(createTagKeySelectEl(key, value));

	inp = document.createElement('select');
	inp.id = 'tag-value-select-' + num_tag_elements;
	$("#" + inp.id).remove();
	inp.setAttribute('class', 'image_form_inp_elements');
	if(typeof value != 'undefined' && tags_object.hasOwnProperty(key)) {
		var loopIter = 1;
		var selectIndex = 0;
		inp.options[0] = new Option("Select", "");
		for( var loop = 0; loop <  tags_object[key].length; loop++) {
			var option = new Option(tags_object[key][loop], tags_object[key][loop]);
			if(value == tags_object[key][loop]) {
				selectIndex = loopIter;
			}
			inp.add(option);
			loopIter++;
		}
		inp.selectedIndex = selectIndex;
	}
	inp.setAttribute('onChange', 'updateKeyValPairs()');
	div.appendChild(inp);

	if(num_tag_elements <= 3) {
		inp = document.createElement('a');
		inp.setAttribute('target_obj', num_tag_elements);
		inp.setAttribute("class", "btn btn-inline")
			inp.innerHTML= '+';
		inp.setAttribute('href', 'javascript:setTagElements(true)');
		div.appendChild(inp);
	}

	return div;

}

function createTagKeySelectEl(selectedKey, value) {
	var inp = document.createElement('select');
	inp.id = 'tag-key-select-' + num_tag_elements;
	inp.setAttribute('class', 'image_form_inp_elements');
	inp.setAttribute('target_obj', "tag-value-select-" + num_tag_elements);
	inp.setAttribute('onChange', "populateTagValues(this)");

	inp.options[inp.options.length] = new Option('Select', '');
	var loopIter = 1;
	var selectIndex = 0;
	for( var key in tags_object) {
		if(typeof selectedKey != 'undefined' && key == selectedKey) {
			selectIndex = loopIter;
		}
		inp.options[inp.options.length] = new Option(key, key);
		loopIter++;
	}
	inp.selectedIndex = selectIndex;

	return inp;

}

function populateTagValues(el, value) {
//	var el = document.getElementById("tag-key-select");
	var selected_key = (el.options[el.selectedIndex].value);
	var vals_el = document.getElementById(el.getAttribute("target_obj"));
	var i;
	for(i=vals_el.options.length-1;i>=0;i--) {
		vals_el.remove(i);
	}
	
	updateKeyValPairs();

	vals_el.options = [];
	//vals_el.options[0] = new Option("Select", "");
	vals_el.appendChild(new Option("Select", ""));
	if(selected_key.trim() == "") { return; }
	var loopIter = 1;
	var selectIndex = 0;
	for( var loop = 0; loop <  tags_object[selected_key].length; loop++) {
		vals_el.options[vals_el.options.length] = new Option(tags_object[selected_key][loop], tags_object[selected_key][loop]);
		if(typeof value != 'undefined' && value == tags_object[selected_key][loop]) {
			selectIndex = loopIter;
		}
	}
	vals_el.selectedIndex = selectIndex;
}

function updateKeyValPairs() {

	var assetTags = {};
	assetTags['trust'] = 'true';
	var tagKeyValJSON= {};
	for(var i = 0; i < 5; i++) {
		if($('#tag-key-select-'+i).length != 0) {
			if($('#tag-key-select-'+i)[0].value.trim() == "" || $('#tag-value-select-'+i)[0].value.trim() == ""){ continue; }
			if(tagKeyValJSON.hasOwnProperty($('#tag-key-select-'+i)[0].value)) {
				tagKeyValJSON[$('#tag-key-select-'+i)[0].value].push($('#tag-value-select-'+i)[0].value);
			} else {
				tagKeyValJSON[$('#tag-key-select-'+i)[0].value] = [];
				tagKeyValJSON[$('#tag-key-select-'+i)[0].value].push($('#tag-value-select-'+i)[0].value);
			}
		}
	}
	assetTags['tags'] = tagKeyValJSON;
	document.getElementById('id_geoTag').value = JSON.stringify(assetTags);
}
