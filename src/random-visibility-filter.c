#include "random-visibility-filter.h"

#include <obs.h>
#include <stdlib.h>

#define S_TIMER_ENABLED       "timer_enabled"
#define S_INTERVAL_SEC        "interval_sec"
#define S_TRIGGER_ON_ACTIVATE "trigger_on_activate"
#define S_AVOID_REPEAT        "avoid_repeat"
#define S_TRIGGER_NOW         "trigger_now"

#define DEFAULT_INTERVAL_SEC 30.0

/*
 * The filter is meant to be attached directly to a scene or a group
 * source (both resolve via obs_scene_from_source). On each trigger it
 * hides whichever of its direct child sources it last made visible,
 * randomly picks a new one (optionally avoiding an immediate repeat),
 * and shows that one instead.
 */
struct rsv_filter {
	obs_source_t *context;

	bool timer_enabled;
	double interval_sec;
	bool trigger_on_activate;
	bool avoid_repeat;

	double elapsed;
	obs_weak_source_t *current_source;

	obs_hotkey_id hotkey_id;
};

struct rsv_item_list {
	obs_sceneitem_t **items;
	size_t count;
	size_t capacity;
};

static bool rsv_enum_item_cb(obs_scene_t *scene, obs_sceneitem_t *item, void *param)
{
	UNUSED_PARAMETER(scene);
	struct rsv_item_list *list = param;

	if (list->count == list->capacity) {
		size_t new_cap = list->capacity ? list->capacity * 2 : 8;
		list->items = brealloc(list->items, new_cap * sizeof(obs_sceneitem_t *));
		list->capacity = new_cap;
	}

	obs_sceneitem_addref(item);
	list->items[list->count++] = item;
	return true;
}

static void rsv_trigger(struct rsv_filter *f)
{
	if (!f->context)
		return;

	obs_source_t *parent = obs_filter_get_parent(f->context);
	if (!parent) {
		blog(LOG_WARNING, "[obs-random-source-visibility] filter has no parent source, ignoring trigger");
		return;
	}

	/* Groups resolve via obs_scene_from_source too, so this covers
	 * both "scene" and "folder" (group) containers. */
	obs_scene_t *scene = obs_scene_from_source(parent);
	if (!scene) {
		blog(LOG_WARNING,
		     "[obs-random-source-visibility] attached to '%s', which is not a scene or group - "
		     "this filter must be attached directly to a scene or group, not an individual source",
		     obs_source_get_name(parent));
		return;
	}

	struct rsv_item_list list = {0};
	obs_scene_enum_items(scene, rsv_enum_item_cb, &list);

	if (list.count == 0) {
		blog(LOG_WARNING, "[obs-random-source-visibility] '%s' has no direct child sources to pick from",
		     obs_source_get_name(parent));
		bfree(list.items);
		return;
	}

	obs_source_t *previous = NULL;
	if (f->current_source) {
		obs_source_t *cur = obs_weak_source_get_source(f->current_source);
		if (cur) {
			for (size_t i = 0; i < list.count; i++) {
				if (obs_sceneitem_get_source(list.items[i]) == cur) {
					obs_sceneitem_set_visible(list.items[i], false);
					break;
				}
			}
			previous = cur;
			obs_source_release(cur);
		}
		obs_weak_source_release(f->current_source);
		f->current_source = NULL;
	}

	size_t idx = (size_t)rand() % list.count;
	if (f->avoid_repeat && list.count > 1 && previous) {
		while (obs_sceneitem_get_source(list.items[idx]) == previous)
			idx = (size_t)rand() % list.count;
	}

	obs_sceneitem_set_visible(list.items[idx], true);
	f->current_source = obs_source_get_weak_source(obs_sceneitem_get_source(list.items[idx]));

	for (size_t i = 0; i < list.count; i++)
		obs_sceneitem_release(list.items[i]);
	bfree(list.items);
}

static void rsv_hotkey_callback(void *data, obs_hotkey_id id, obs_hotkey_t *hotkey, bool pressed)
{
	UNUSED_PARAMETER(id);
	UNUSED_PARAMETER(hotkey);
	if (!pressed)
		return;
	rsv_trigger((struct rsv_filter *)data);
}

static bool rsv_trigger_now_clicked(obs_properties_t *props, obs_property_t *property, void *data)
{
	UNUSED_PARAMETER(props);
	UNUSED_PARAMETER(property);
	rsv_trigger((struct rsv_filter *)data);
	return false;
}

static const char *rsv_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return obs_module_text("FilterName");
}

static void rsv_update(void *data, obs_data_t *settings)
{
	struct rsv_filter *f = data;
	f->timer_enabled = obs_data_get_bool(settings, S_TIMER_ENABLED);
	f->interval_sec = obs_data_get_double(settings, S_INTERVAL_SEC);
	if (f->interval_sec < 0.1)
		f->interval_sec = 0.1;
	f->trigger_on_activate = obs_data_get_bool(settings, S_TRIGGER_ON_ACTIVATE);
	f->avoid_repeat = obs_data_get_bool(settings, S_AVOID_REPEAT);
}

static void *rsv_create(obs_data_t *settings, obs_source_t *context)
{
	struct rsv_filter *f = bzalloc(sizeof(struct rsv_filter));
	f->context = context;

	rsv_update(f, settings);

	f->hotkey_id = obs_hotkey_register_source(context, "rsv.trigger", obs_module_text("TriggerHotkey"),
						   rsv_hotkey_callback, f);

	return f;
}

static void rsv_destroy(void *data)
{
	struct rsv_filter *f = data;

	obs_hotkey_unregister(f->hotkey_id);

	if (f->current_source)
		obs_weak_source_release(f->current_source);

	bfree(f);
}

static void rsv_activate(void *data)
{
	struct rsv_filter *f = data;
	if (f->trigger_on_activate)
		rsv_trigger(f);
}

static void rsv_video_tick(void *data, float seconds)
{
	struct rsv_filter *f = data;
	if (!f->timer_enabled)
		return;

	f->elapsed += (double)seconds;
	if (f->elapsed >= f->interval_sec) {
		f->elapsed = 0.0;
		rsv_trigger(f);
	}
}

static void rsv_video_render(void *data, gs_effect_t *effect)
{
	UNUSED_PARAMETER(effect);
	struct rsv_filter *f = data;
	obs_source_skip_video_filter(f->context);
}

static obs_properties_t *rsv_properties(void *data)
{
	obs_properties_t *props = obs_properties_create();

	struct rsv_filter *f = data;
	obs_source_t *parent = f ? obs_filter_get_parent(f->context) : NULL;
	if (parent && !obs_scene_from_source(parent))
		obs_properties_add_text(props, "rsv_misattached_warning", obs_module_text("MisattachedWarning"),
					 OBS_TEXT_INFO);

	obs_properties_add_bool(props, S_TIMER_ENABLED, obs_module_text("TimerEnabled"));

	obs_property_t *interval = obs_properties_add_float_slider(props, S_INTERVAL_SEC,
								     obs_module_text("IntervalSec"), 0.5, 3600.0, 0.5);
	obs_property_float_set_suffix(interval, " s");

	obs_properties_add_bool(props, S_TRIGGER_ON_ACTIVATE, obs_module_text("TriggerOnActivate"));
	obs_properties_add_bool(props, S_AVOID_REPEAT, obs_module_text("AvoidRepeat"));

	obs_properties_add_button2(props, S_TRIGGER_NOW, obs_module_text("TriggerNow"), rsv_trigger_now_clicked, data);

	return props;
}

static void rsv_defaults(obs_data_t *settings)
{
	obs_data_set_default_bool(settings, S_TIMER_ENABLED, false);
	obs_data_set_default_double(settings, S_INTERVAL_SEC, DEFAULT_INTERVAL_SEC);
	obs_data_set_default_bool(settings, S_TRIGGER_ON_ACTIVATE, true);
	obs_data_set_default_bool(settings, S_AVOID_REPEAT, true);
}

struct obs_source_info rsv_filter_get_info(void)
{
	struct obs_source_info info = {0};
	info.id = "random_source_visibility_filter";
	info.type = OBS_SOURCE_TYPE_FILTER;
	info.output_flags = OBS_SOURCE_VIDEO;
	info.get_name = rsv_get_name;
	info.create = rsv_create;
	info.destroy = rsv_destroy;
	info.update = rsv_update;
	info.get_defaults = rsv_defaults;
	info.get_properties = rsv_properties;
	info.activate = rsv_activate;
	info.video_tick = rsv_video_tick;
	info.video_render = rsv_video_render;
	return info;
}
