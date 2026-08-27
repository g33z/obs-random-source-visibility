#include <obs-module.h>
#include <util/platform.h>
#include <stdlib.h>

#include "random-visibility-filter.h"

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("obs-random-source-visibility", "en-US")
OBS_MODULE_AUTHOR("g33z")

MODULE_EXPORT const char *obs_module_description(void)
{
	return "Randomly toggles the visibility of one source within a scene or group.";
}

bool obs_module_load(void)
{
	srand((unsigned int)os_gettime_ns());

	struct obs_source_info info = rsv_filter_get_info();
	obs_register_source(&info);

	blog(LOG_INFO, "[obs-random-source-visibility] plugin loaded (version %s)", PLUGIN_VERSION);
	return true;
}

void obs_module_unload(void)
{
	blog(LOG_INFO, "[obs-random-source-visibility] plugin unloaded");
}
