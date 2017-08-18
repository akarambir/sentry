import React from 'react';

import ApiMixin from '../../mixins/apiMixin';
import GroupState from '../../mixins/groupState';
import LoadingError from '../../components/loadingError';
import LoadingIndicator from '../../components/loadingIndicator';
import Pagination from '../../components/pagination';
import EventsTable from '../../components/eventsTable/eventsTable';
import {t} from '../../locale';

const GroupAllEvents = React.createClass({
  mixins: [ApiMixin, GroupState],

  getInitialState() {
    let queryParams = this.props.location.query;
    return {
      eventList: [],
      loading: true,
      error: false,
      pageLinks: '',
      query: queryParams.query || ''
    };
  },

  componentWillMount() {
    this.fetchData();
  },

  componentWillReceiveProps(nextProps) {
    if (
      nextProps.params.groupId !== this.props.params.groupId ||
      nextProps.location.search !== this.props.location.search
    ) {
      let queryParams = nextProps.location.query;
      this.setState(
        {
          query: queryParams.query
        },
        this.fetchData
      );
    }
  },

  getEndpoint() {
    let params = this.props.params;
    let queryParams = {
      ...this.props.location.query,
      limit: 50,
      query: this.state.query
    };

    return `/issues/${params.groupId}/events/?${jQuery.param(queryParams)}`;
  },

  fetchData() {
    let queryParams = this.props.location.query;

    this.setState({
      loading: true,
      error: false
    });

    this.api.request(this.getEndpoint(), {
      method: 'GET',
      data: queryParams,
      success: (data, _, jqXHR) => {
        this.setState({
          eventList: data,
          error: false,
          loading: false,
          pageLinks: jqXHR.getResponseHeader('Link')
        });
      },
      error: err => {
        let error = err.responseJSON || true;
        error = error.detail || true;
        this.setState({
          error,
          loading: false
        });
      }
    });
  },

  renderNoQueryResults() {
    return (
      <div className="box empty-stream">
        <span className="icon icon-exclamation" />
        <p>{t('Sorry, no events match your search query.')}</p>
      </div>
    );
  },

  renderEmpty() {
    return (
      <div className="box empty-stream">
        <span className="icon icon-exclamation" />
        <p>{t("There don't seem to be any events yet.")}</p>
      </div>
    );
  },

  renderResults() {
    let group = this.getGroup();
    let tagList = group.tags.filter(tag => tag.key !== 'user') || [];

    return (
      <div>
        <div className="event-list">
          <EventsTable
            tagList={tagList}
            events={this.state.eventList}
            params={this.props.params}
          />
        </div>
        <Pagination pageLinks={this.state.pageLinks} />
      </div>
    );
  },

  render() {
    let hasEvents = this.state.eventList.length > 0;

    if (this.state.loading) {
      return <LoadingIndicator />;
    }

    if (this.state.error) {
      return <LoadingError message={this.state.error} onRetry={this.fetchData} />;
    }

    if (hasEvents) {
      return this.renderResults();
    }

    if (this.state.query && this.state.query !== '') return this.renderNoQueryResults();

    return this.renderEmpty();
  }
});

export default GroupAllEvents;
